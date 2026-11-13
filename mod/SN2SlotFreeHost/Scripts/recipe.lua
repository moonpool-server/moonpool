-- recipe.lua: what the container adds to SN2SlotFreeHost: the moonpool control queue, status.json,
-- the idle freeze and the player commands. Hosting itself stays in main.lua. Original code, MIT.
local json = require('json')
local protocol = require('protocol')
local status = require('status')
local host_core = require('sn2_host_core')
local controller_named = host_core.controller_named
local idle = require('idle')
local save_policy = require('save_policy')
local access = require('access')
local voice_range = require('voice_range')
local notify = require('notify')
local hosted_poll_gate = require('hosted_poll')

local log = host_core.log
-- GetFullName() is "<Class> <path>"; StaticFindObject takes the path alone.
local object_path = status.object_path

-- Configuration --------------------------------------------------------------

local DEFAULTS = {
  control_dir = (function()
    -- The launcher exports both; DATA_DIR differs per image (/data, /home/container).
    local c = os.getenv('SN2_CONTROL_WIN'); if c and c ~= '' then return c end
    local d = os.getenv('SN2_DATA_WIN'); if d and d ~= '' then return d .. '\\control' end
    return 'Z:\\data\\control' -- outside the container only
  end)(),
  poll_ms = 2000,
  -- Seconds between two in-game "!" admin commands: each can stall the server for a second or two.
  admin_gap_s = 10,
  host = {
    save_slot = 'Slot1',
    max_players = 4,
  },
  enabled_commands = { 'status', 'players', 'kick', 'save', 'slots', 'friend_code' },
}

local read_file = host_core.read_file

local function merge(base, over)
  for k, v in pairs(over) do
    if type(v) == 'table' and type(base[k]) == 'table' and #v == 0 and next(v) ~= nil then
      merge(base[k], v)
    else
      base[k] = v
    end
  end
  return base
end

local function load_config()
  local cfg = merge({}, DEFAULTS)
  cfg.host = merge({}, DEFAULTS.host)
  -- config.json sits next to Scripts/ in the mod folder; UE4SS runs with the
  -- game's Win64 folder as working directory.
  local raw = read_file('ue4ss-exp\\Mods\\SN2SlotFreeHost\\config.json')
    or read_file('ue4ss\\Mods\\SN2SlotFreeHost\\config.json')
  if raw then
    local ok, parsed = pcall(json.decode, raw)
    if ok and type(parsed) == 'table' then
      merge(cfg, parsed)
    else
      log('config.json unreadable, using defaults: ' .. tostring(parsed))
    end
  end
  local enabled = {}
  for _, name in ipairs(cfg.enabled_commands) do
    if protocol.ALLOWLIST[name] then enabled[name] = true
    else log('ignoring unknown command in config: ' .. tostring(name)) end
  end
  cfg.enabled_set = enabled
  return cfg
end

local CFG = load_config()
local GAME_BUILD_ID = os.getenv('SN2_GAME_BUILD_ID') or 'unknown'
local HOST_NAME = os.getenv('SN2_HOST_NAME') or 'SN2 Host'
-- PLAYER_SLOTS + 1 from the launcher: the host account holds a player slot.
local env_limit = tonumber(os.getenv('SN2_SESSION_LIMIT') or '')
if env_limit and env_limit >= 2 and env_limit <= 64 then CFG.host.max_players = env_limit end
local DIR = os.getenv('SN2_CONTROL_WIN') or CFG.control_dir
if CFG.control_dir ~= DEFAULTS.control_dir then DIR = CFG.control_dir end
host_core.configure({ dir = DIR })
local cpath = host_core.cpath

local function write_atomic(dest, tbl)
  local tmp = cpath('tmp', 'mod-' .. tostring(os.time()) .. '-' .. tostring(math.random(1, 1e9)) .. '.json')
  local encoded = json.encode(tbl)
  if dest:find('\\outbox\\', 1, true) and #encoded > protocol.MAX_RESPONSE_BYTES then
    local id = dest:match('\\([0-9a-f]+)%.json$') or ''
    encoded = json.encode(protocol.result(id, false, {}, 'response_too_large', GAME_BUILD_ID))
  end
  local f, err = io.open(tmp, 'wb')
  if not f then log('cannot write ' .. tmp .. ': ' .. tostring(err)); return false end
  f:write(encoded)
  f:close()
  os.remove(dest)
  local ok, rerr = os.rename(tmp, dest)
  if not ok then log('rename failed ' .. dest .. ': ' .. tostring(rerr)); os.remove(tmp) end
  return ok
end

local function answer(id, ok, data, err)
  return protocol.result(id, ok, data, err, GAME_BUILD_ID)
end

-- Game objects ---------------------------------------------------------------

local valid = host_core.valid
local to_str = host_core.to_str

local function find(class)
  local ok, obj = pcall(FindFirstOf, class)
  if ok and valid(obj) then return obj end
  return nil
end

local state = { started = os.time() }
-- Player limits: the subsystem's MaxSessionPlayerCount and the lobby game mode's GameSession.MaxPlayers.
local function read_limits(sub, gm)
  local r = {}
  pcall(function() r.max_session_player_count = sub.MaxSessionPlayerCount end)
  pcall(function() r.game_session_max_players = gm.GameSession.MaxPlayers end)
  return r
end

local function set_limits(sub, gm, cap)
  if sub then pcall(function() sub.MaxSessionPlayerCount = cap end) end
  if gm then pcall(function() gm.GameSession.MaxPlayers = cap end) end
  local r = read_limits(sub, gm)
  log(string.format('player limit %d: MaxSessionPlayerCount=%s GameSession.MaxPlayers=%s',
    cap, tostring(r.max_session_player_count), tostring(r.game_session_max_players)))
  return r
end

-- An explicit save name wins, then SAVE_SELECT, then the newest .sav, then the new-world slot.
local function pick_save(explicit)
  if explicit and explicit ~= '' then return explicit end
  local sel = (read_file(cpath('SAVE_SELECT')) or ''):match('^%s*([%w_%-]+)%s*$')
  if sel then return sel end
  local dir = os.getenv('SN2_SAVE_WIN')
  if dir then
    local p = io.popen('dir /b /o-d "' .. dir .. '\\*.sav" 2>nul')
    if p then
      for line in p:lines() do
        local name = line:match('^(.-)%.sav%s*$')
        if name and not name:match('Settings$') and not name:match('Cache$')
          and not name:match('SavedState$') then p:close(); return name end
      end
      p:close()
    end
  end
  return CFG.host.save_slot
end
_G.SN2_PICK_SAVE = pick_save

-- Commands -------------------------------------------------------------------

local ps_name = host_core.ps_name

local function players(refresh)
  if refresh then status.invalidate() end
  return status.players(to_str)
end

local handlers = {
  status = function()
    return true, { uptime_s = os.time() - state.started, hosted = _G.SN2_HOSTED == true }
  end,
  players = function() return true, { players = players(true) } end,
}
_G.SN2_HANDLERS = handlers -- read by tests/lua/host_behaviour_spec.lua

handlers.save = function()
  local pc = controller_named(HOST_NAME)
  if not pc then return false, nil, 'host_controller_not_found' end
  local component
  pcall(function() component = pc.SaveCommunication end)
  if not valid(component) then return false, nil, 'save_communication_not_found' end
  local ok, err = pcall(function() component:TriggerAsyncAutoSaveGame(true) end)
  if not ok then
    log('forced save request failed: ' .. tostring(err))
    return false, nil, 'save_request_failed:' .. tostring(err)
  end
  log('forced save requested on the host controller')
  return true, { forced = true, queued = true }
end

local run_as = host_core.run_as

handlers.player = function(args)
  local pc = controller_named(args.player)
  if not pc then return false, nil, 'unknown_player' end
  run_as(pc, args.command, args.player)
  return true, { player = args.player, command = args.command, queued = true }
end

handlers.kick = function(args)
  if not controller_named(args.player) then return false, nil, 'unknown_player' end
  return handlers.player({ player = HOST_NAME, command = 'KickPlayer ' .. args.player })
end

-- settings.yaml (settings.lua): read once hosted and on `moonpool settings apply`; only a key
-- with a verified command runs, as the host's own controller.
local settings = require('settings')
local set_weather -- defined beside the weather readback below
local settings_block, settings_readback -- defined beside the readbacks below
local function apply_settings(why)
  local cfg, err = settings.parse(read_file(cpath('settings.yaml')))
  if not cfg then
    log('settings (' .. why .. '): ' .. err)
    state.settings = nil
    return nil, err
  end
  local p = settings.plan(cfg)
  local host_pc = #p.apply > 0 and controller_named(HOST_NAME) or nil
  local ran = {}
  for _, a in ipairs(p.apply) do
    if a.key == 'weather' then
      local ok, miss = set_weather(a.line)
      if ok then
        ran[#ran + 1] = a
      else
        p.refused[#p.refused + 1] = { key = a.key, value = a.value, desired = a.desired, reason = miss }
      end
    elseif host_pc then
      run_as(host_pc, a.line, 'settings ' .. a.key)
      -- The idle freeze owns the clock while nobody is in, so it is handed the operator's hold.
      if a.key == 'daylight' then state.daylight_frozen = (a.line == 'FreezeTime') end
      ran[#ran + 1] = a
    else
      p.refused[#p.refused + 1] = { key = a.key, value = a.value, desired = a.desired,
        reason = 'host controller not found' }
    end
  end
  p.apply = ran
  for _, r in ipairs(p.refused) do
    log(string.format('settings (%s): %s=%s refused: %s', why, r.key, tostring(r.value), r.reason))
  end
  log(string.format('settings (%s): %d applied, %d refused', why, #p.apply, #p.refused))
  -- Every status write judges the readbacks against this submission; nothing applies it again.
  state.settings = { plan = p, track = settings.submission(p) }
  return p
end
-- What was asked, what ran, what was refused and why, and what the readbacks show now.
-- `verified_at` is set by a status write, never by this answer.
handlers.settings = function()
  local p, err = apply_settings('moonpool')
  if not p then return false, nil, err end
  local block = settings_block(settings_readback())
  local a = { requested = {}, submitted = {}, refused = {}, observed = {}, settings = {}, values = block.values }
  for _, v in ipairs(p.values) do
    a.requested[#a.requested + 1] = { key = v.key, value = v.value, desired = v.desired }
  end
  for _, x in ipairs(p.apply) do a.submitted[#a.submitted + 1] = { key = x.key, value = x.desired } end
  for _, r in ipairs(p.refused) do a.refused[#a.refused + 1] = { key = r.key, value = r.value, reason = r.reason } end
  for _, k in ipairs(settings.KEYS) do
    local row = block[k]
    if row then
      a.settings[k] = row
      if row.observed ~= json.null then a.observed[k] = row.observed end
    end
  end
  return true, a
end

-- The game's saved signal store (UWEPingSystemComponent) and one location ping in it.
local ping_store_name
local function saved_ping_store()
  if ping_store_name then
    local object = StaticFindObject(ping_store_name)
    if valid(object) then return object end
  end
  local object = find('UWEPingSystemComponent')
  if valid(object) then
    local full = to_str(object:GetFullName())
    ping_store_name = full and full:match('^%S+%s+(.+)$') or full
    return object
  end
end
local LOCATION_PING = '/Game/Data/Pings/DA_LocationPing.DA_LocationPing'
local function add_location_ping(store, name, pos, tracking, color)
  local data = StaticFindObject(LOCATION_PING)
  if not valid(data) then return nil, 'location ping data unavailable' end
  local out = {}
  -- UE4SS fills an FStructProperty out parameter into the table passed in.
  store:AddPing(pos, FText(name), data, 0.0, nil, tracking, out,
    false, tracking ~= nil, color)
  return out
end

-- moonpool diag friend-code (EXPERIMENTAL): the Sonar code from the game's Friends view model.
local friend_code = require('friend_code')
local SONAR_FILE = cpath('sonar-code.txt')
local FRIENDS_SCREEN = '/Game/Blueprints/UI/Friends/WBP_InGameFriends.WBP_InGameFriends_C'
-- A kept code is shown only for the account that made it.
local HOST_SID = os.getenv('SN2_HOST_STEAMID') or ''
do
  local kept, sid = (read_file(SONAR_FILE) or ''):match('^%s*(%S+)%s+(%d+)%s*$')
  if HOST_SID ~= '' and sid == HOST_SID and friend_code.is_code(kept) then state.friend_code = kept end
end
local FC_GAME = {
  find_vm = function() local v = FindFirstOf('SN2InGameFriendScreenViewModel'); return valid(v) and v or nil end,
  others = function()
    local n = 0
    for _, p in ipairs(players()) do if p.name ~= HOST_NAME then n = n + 1 end end
    return n
  end,
  call = function(vm, f) return pcall(function() vm[f](vm) end) end,
  read = function(vm, p)
    local v; pcall(function() v = to_str(vm[p]) end)
    return v
  end,
  props = function(vm)
    local names = {}
    pcall(function()
      vm:GetClass():ForEachProperty(function(prop) names[#names + 1] = prop:GetFName():ToString() end)
    end)
    return names
  end,
  -- Headless, so the Friends screen is built the game's way: its widget, which owns the view model.
  open_screen = function()
    local pc = FindFirstOf('PlayerController')
    if not valid(pc) then return false, 'no player controller' end
    local cls = StaticFindObject(FRIENDS_SCREEN)
    if not valid(cls) and type(_G.LoadAsset) == 'function' then
      pcall(function() cls = _G.LoadAsset(FRIENDS_SCREEN) end)
    end
    if not valid(cls) then return false, 'no Friends screen class' end
    local lib = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    if not valid(lib) then return false, 'no widget library' end
    local ok, err = pcall(function()
      local w = lib:Create(pc, cls, pc)
      if not valid(w) then error('Create returned nothing') end
      w:AddToViewport(0)
      state.friend_screen = w
    end)
    if not ok then return false, tostring(err) end
    return true
  end,
  close_screen = function()
    local w = state.friend_screen
    state.friend_screen = nil
    if valid(w) then pcall(function() w:RemoveFromParent() end) end
  end,
}
local FC_HINT = 'the game made no code; the guide says what a headless host can do'
handlers.friend_code = function(args)
  ExecuteInGameThread(function()
    local job, why = friend_code.start(FC_GAME, args.force == true)
    if not job then
      log('friend-code: refused: ' .. tostring(why) .. (why == 'no_view_model' and ('; ' .. FC_HINT) or ''))
      return
    end
    log(job.how == 'opened' and 'friend-code: opened the Friends screen the way a click does'
      or 'friend-code: requested from the open Friends screen')
    -- Set on the game thread after the loop returns, so the next round ends the loop.
    local done = false
    LoopAsync(2000, function()
      if done then return true end
      ExecuteInGameThread(function()
        if done then return end
        local code, how = friend_code.poll(FC_GAME, job)
        if code then
          state.friend_code = code
          if HOST_SID ~= '' then
            local f = io.open(SONAR_FILE, 'wb')
            if f then f:write(code, ' ', HOST_SID, '\n'); f:close() end
          end
          log('friend-code: ' .. code .. ' (' .. how .. ')')
          done = true
        elseif how == 'view_model_gone' then
          log('friend-code: the Friends screen closed before a code came; ' .. FC_HINT)
          done = true
        elseif how == 'timeout' then
          log('friend-code: no answer in ' .. friend_code.MAX_TICKS * 2 .. ' s; ' .. FC_HINT)
          done = true
        end
        if done then friend_code.finish(FC_GAME, job) end
      end)
      return done
    end)
  end)
  return true, { queued = true, experimental = true }
end

-- Shared unlocks (unlock_replay.lua): the host's unlocks are sent to every player, and a joiner
-- gets the starter set plus all of them as one batch.
local unlocks = require('unlock_replay')
local UNLOCK_REPLAY_ENABLED = (os.getenv('SN2_UNLOCK_REPLAY') or 'true') ~= 'false'
local function prev_status()
  local raw = read_file(cpath('status.json'))
  if not raw then return nil end
  local ok, t = pcall(json.decode, raw)
  return ok and t or nil
end
unlocks.interval = unlocks.interval_ms(os.getenv('SN2_UNLOCK_INTERVAL_MS'))
local UNLOCKS = unlocks.seed(state.save or os.getenv('SN2_SAVE_NAME') or 'newest', prev_status())
local asset_index -- the join replay's name lookups, defined with the index below
local UNLOCK_GAME = {
  -- Lines go `interval` ms apart (UNLOCK_INTERVAL_MS): a 20 ms burst froze the client's toolbar.
  send = function(player, lines, interval)
    local pc = controller_named(player, true)
    if not pc then log('unlocks: ' .. player .. ' gone before ' .. #lines .. ' lines'); return end
    local ksl = StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    local world = pc:GetWorld()
    local failed, total = 0, #lines
    log(string.format('unlocks: %d lines to %s, %d ms apart', total, player, interval or 0))
    for _, item in ipairs(unlocks.schedule(lines, interval or 0)) do
      ExecuteWithDelay(item.at, function() ExecuteInGameThread(function()
        local ok, err = pcall(function()
          if not valid(pc) then error('controller gone') end
          ksl:ExecuteConsoleCommand(world, item.line, pc)
        end)
        if not ok then
          failed = failed + 1
          if failed == 1 then log('unlocks: ' .. item.line .. ' as ' .. player .. ' failed: ' .. tostring(err)) end
        end
        if item.at == (total - 1) * (interval or 0) and failed > 1 then
          log('unlocks: ' .. failed .. ' of ' .. total .. ' lines failed as ' .. player)
        end
      end) end)
    end
  end,
  now = function() return os.time() * 1000 end,
  has_body = function(player)
    local pc = controller_named(player)
    local b = false
    if pc then
      pcall(function() local pw = pc.PlayerState.PawnPrivate; b = pw ~= nil and pw:IsValid() end)
      if not b then pcall(function() b = valid(pc.Pawn) end) end
    end
    return b
  end,
  -- FNames compare without case, so the game's own spelling is returned.
  exists = function(name)
    local idx = asset_index()
    return idx and idx.names[tostring(name):lower()] or false
  end,
  log = log,
}
-- One FindAllOf('DataAsset') builds every lookup: walking all objects per name froze the game
-- thread for a minute on a join and crashed UE4SS. Rebuilt at most once a minute on a scan miss.
local ASSET_INDEX, ASSET_INDEX_AT = nil, -60
local function build_asset_index()
  local idx, names, scans = { names = {}, scans = {}, items = {} }, 0, 0
  local started = os.clock()
  local ok, all = pcall(FindAllOf, 'DataAsset')
  for _, o in ipairs(ok and type(all) == 'table' and all or {}) do
    local short; pcall(function() short = o:GetFName():ToString() end)
    if type(short) == 'string' and short ~= '' then
      local k = short:lower()
      if not idx.names[k] then idx.names[k] = short; names = names + 1 end
      local base = short:match('^DA_(.+)_ItemType$')
      if base then
        local display
        for _, field in ipairs({ 'DisplayName', 'Name' }) do
          if not display then pcall(function() display = o[field]:ToString() end) end
        end
        if type(display) ~= 'string' or display == '' then display = base:gsub('_', ' '):gsub('(%l)(%u)', '%1 %2') end
        idx.items[#idx.items + 1] = { id = short, name = display }
      end
      if short:match('^DA_.+_ScanData$') then
        local okn, display = pcall(function() return o.Name:ToString() end)
        if okn and type(display) == 'string' and display ~= '' then
          local list = idx.scans[display] or {}
          idx.scans[display] = list
          local seen = false
          for _, a in ipairs(list) do if a == short then seen = true end end
          if not seen then list[#list + 1] = short; scans = scans + 1 end
        end
      end
    end
  end
  log(string.format('asset index: %d data assets, %d scan data, %.0f ms', names, scans, (os.clock() - started) * 1000))
  return idx
end
asset_index = function(rebuild)
  if (not ASSET_INDEX or rebuild) and os.time() - ASSET_INDEX_AT >= 60 then
    ASSET_INDEX_AT = os.time()
    local ok, idx = pcall(build_asset_index)
    if ok then ASSET_INDEX = idx else log('asset index failed: ' .. tostring(idx)) end
  end
  return ASSET_INDEX
end
UNLOCK_GAME.scan_assets = function(display)
  local idx = asset_index()
  if idx and not idx.scans[display] then idx = asset_index(true) end
  return idx and idx.scans[display] or {}
end
_G.SN2_UNLOCK_GAME = UNLOCK_GAME -- read by tests/lua/host_behaviour_spec.lua
_G.SN2_ASSET_INDEX_RESET = function() ASSET_INDEX, ASSET_INDEX_AT = nil, -60 end -- tests only
-- Named players whose controller exists, so the Unlock lines can run as them.
local function player_names()
  local out = {}
  for _, p in ipairs(players()) do
    if p.name ~= '?' and controller_named(p.name, true) then out[#out + 1] = p.name end
  end
  return out
end
local function unlock_line(l)
  local piece = unlocks.line(UNLOCKS, l)
  if piece then unlocks.broadcast(UNLOCK_GAME, piece, player_names(), HOST_NAME) end
  local scan = unlocks.scan(UNLOCKS, l)
  if scan then unlocks.scan_broadcast(UNLOCKS, UNLOCK_GAME, scan, player_names(), HOST_NAME) end
end
handlers.unlocks = function(args)
  if not UNLOCK_REPLAY_ENABLED then return false, nil, 'disabled_by_config' end
  local who = args.player
  if who and not controller_named(who) then return false, nil, 'unknown_player' end
  local targets = {}
  if who then targets = { who } else
    for _, n in ipairs(player_names()) do if n ~= HOST_NAME then targets[#targets + 1] = n end end
  end
  ExecuteInGameThread(function()
    for _, n in ipairs(targets) do unlocks.replay(UNLOCKS, UNLOCK_GAME, n) end
  end)
  return true, { players = targets, starter = unlocks.STARTER, pieces = UNLOCKS.pieces,
    scans = UNLOCKS.scans, queued = true }
end

-- moonpool server slots N: the live limit until the next start, read back.
handlers.slots = function(args)
  local cap = idle.session_limit(args.slots)
  if not cap then return false, nil, 'slots_out_of_range' end
  local sub, gm = find('UWEOnlineSessionSubsystem'), find('BP_ClientLobbyGameMode_C')
  local r = set_limits(sub, gm, cap)
  local world
  if not gm then
    local gs = find('GameSession')
    if gs then
      pcall(function() gs.MaxPlayers = cap end)
      pcall(function() world = gs.MaxPlayers end)
    end
  end
  CFG.host.max_players, state.player_slots = cap, args.slots
  local took = {
    lobby_subsystem = r.max_session_player_count == cap,
    lobby_game_session = gm ~= nil and r.game_session_max_players == cap,
    world_game_session = world == cap,
  }
  log(string.format('slots %d (limit %d): MaxSessionPlayerCount=%s lobby MaxPlayers=%s world MaxPlayers=%s',
    args.slots, cap, tostring(r.max_session_player_count),
    tostring(r.game_session_max_players), tostring(world)))
  return true, { slots = args.slots, limit = cap, read_back = {
    max_session_player_count = r.max_session_player_count,
    lobby_game_session_max_players = r.game_session_max_players,
    world_game_session_max_players = world }, took = took }
end

-- In-game administration through the PDA's Signals > EDIT screen. The hook copies plain values;
-- the work waits for the next game-thread poll.
local admin_signal = require('admin_signal')
local admin_pace = require('admin_pace')
local console = require('console')
-- The admin console's words and replies: the shipped console.json, then the host's own
-- console.local.json (copied from the data volume by install-ue4ss.sh) over it, key by key.
local function load_catalog()
  local cat = {}
  for _, dir in ipairs({ 'ue4ss-exp', 'ue4ss' }) do
    local base = dir .. '\\Mods\\SN2SlotFreeHost\\'
    local raw = read_file(base .. 'console.json')
    if raw then
      local ok, c = pcall(json.decode, raw)
      if ok and type(c) == 'table' then cat = c end
      local own = read_file(base .. 'console.local.json')
      local okl, o = pcall(json.decode, own or '')
      if own and okl and type(o) == 'table' then
        for k, v in pairs(o) do
          if type(v) == 'table' and type(cat[k]) == 'table' and #v == 0 then
            for kk, vv in pairs(v) do cat[k][kk] = vv end
          else
            cat[k] = v
          end
        end
      elseif own then
        log('console: console.local.json is not JSON; using the shipped words')
      end
      break
    end
  end
  return cat
end
local CATALOG = load_catalog()
local CONSOLE = console.new(CATALOG)
local EOS_BY_NAME = {} -- from the game log's login lines, for the console's who
local ADMIN = admin_signal.new({ console_word = CATALOG.signal_word, admins = os.getenv('SN2_ADMINS') or '',
  prefix = os.getenv('SN2_ADMIN_PREFIX') or '!' })
local ADMIN_HOOK = '/Script/UWEPingSystem.UWEPingSystemCommandComponent:ServerSetPingDisplayName'
local COLOR_HOOK = '/Script/UWEPingSystem.UWEPingSystemCommandComponent:ServerSetThumbnailColor'
local admin_queue = admin_pace.new(tonumber(CFG.admin_gap_s) or 10)
local admin_hooked, color_hooked = false, false
-- The answer stays on the signal this long, then its own name and colour come back.
local REPLY_SECONDS = 8
local admin_restores = {} -- guid key -> { ping, name, color, at }
local admin_colors = {}   -- guid key -> { color, at }: the colour picked in the same EDIT

-- A hook's parameters live only for the call, so its structs are copied out.
local function guid_copy(g) return { A = g.A, B = g.B, C = g.C, D = g.D } end
local function guid_key(g) return string.format('%d:%d:%d:%d', g.A, g.B, g.C, g.D) end
local function color_copy(c) return { R = c.R, G = c.G, B = c.B, A = c.A } end
local GREEN, RED = { R = 0.1, G = 0.8, B = 0.2, A = 1.0 }, { R = 0.9, G = 0.1, B = 0.1, A = 1.0 }

local function admin_identity(component)
  local name, connection
  pcall(function()
    local ps
    pcall(function() ps = component.PlayerState end)
    if not ps or not ps:IsValid() then ps = component:GetOwner().PlayerState end
    name = ps_name(ps)
  end)
  pcall(function()
    local pc = component:GetOwner()
    if not pc.NetConnection then pc = pc:GetOwner() end
    connection = pc.NetConnection:GetFName():ToString()
  end)
  return { name = name or '?', eos = admin_signal.connection_id(ADMIN, connection) }
end

local function admin_settings(key, value)
  local line = settings.VERIFIED[key] and settings.VERIFIED[key](value)
  if not line then return false, nil, 'value out of range' end
  if key == 'weather' then
    local ok, why = set_weather(line)
    return ok, ok and { value = line } or nil, why
  end
  local pc = controller_named(HOST_NAME)
  if not pc then return false, nil, 'host controller not found' end
  run_as(pc, line, 'in-game admin ' .. key)
  return true, { value = value }
end

-- What the console can see, read from the live game when a line comes in.
local function console_game()
  return { host = HOST_NAME, list = function(kind)
    if kind == 'players' then
      local out = {}
      for _, p in ipairs(players()) do
        if p.name ~= HOST_NAME then
          out[#out + 1] = { id = p.name, name = p.name, eos = EOS_BY_NAME[p.name] or '?', ping = p.ping_ms or '?' }
        end
      end
      return out
    end
    if kind == 'items' then
      local idx = asset_index()
      return idx and idx.items or {}
    end
    if kind == 'tags' then return nil end -- where this build keeps its world tags is not known yet
    return {}
  end }
end

local function admin_call(name, args)
  if name == 'mp' then
    if not CFG.enabled_set.player then return false, nil, console.msg(CONSOLE, 'console_off') end
    local req = { sender = { name = args.sender.name, key = args.sender.eos }, text = args.line }
    local r = args.forwarded and console.forwarded(CONSOLE, req, console_game())
      or console.handle(CONSOLE, req, console_game())
    -- Each line can stall the server for a second or so, so they go line_gap_ms apart.
    local gap = tonumber(CATALOG.line_gap_ms) or 1000
    for i, run in ipairs(r.runs) do
      ExecuteWithDelay((i - 1) * gap, function() ExecuteInGameThread(function()
        local pc = controller_named(run.player)
        if pc then run_as(pc, run.line, 'console ' .. tostring(args.sender.name) .. ' for ' .. run.player)
        else log('console: ' .. run.player .. ' gone before ' .. run.line) end
      end) end)
    end
    local pc = controller_named(args.sender.name)
    if pc then
      for _, l in ipairs(r.lines) do pcall(function() pc:ClientMessage(l, FName('None'), 0.0) end) end
    end
    return true, { lines = r.lines }
  end
  if name == 'ping' then
    local rows = status.players(to_str)
    local lines = {}
    for _, row in ipairs(rows) do
      if row.name ~= HOST_NAME and (args.all or row.name == args.sender.name) then
        local suffix = row.ping_ms ~= nil and (tostring(row.ping_ms) .. ' ms') or 'unknown'
        lines[#lines + 1] = row.name .. ' · ' .. suffix
      end
    end
    if #lines == 0 then return false, nil, 'ping unavailable' end
    return true, { lines = lines }
  end
  if name == 'slots' then return handlers.slots(args) end
  if name == 'time' then
    if args.value == 'frozen' or args.value == 'normal' then return admin_settings('daylight', args.value) end
    return admin_settings('time_of_day', args.value)
  end
  if name == 'weather' then return admin_settings('weather', args.value) end
  if name == 'kick' then
    return handlers.kick(args)
  end
  if name == 'console' then
    if not CFG.enabled_set.player then return false, nil, 'console is off: add player to enabled_commands' end
    return handlers.player({ player = args.sender.name, command = args.line })
  end
  if name == 'unlocks' then return handlers.unlocks(args) end
  if name == 'restart' then
    local ok = write_atomic(cpath('admin-restart-request.json'), { requested_at = os.time(), source = 'in_game' })
    return ok, ok and { requested = true } or nil, ok and nil or 'request file failed'
  end
  if name == 'restart_cancel' then
    local ok = write_atomic(cpath('admin-restart-cancel.json'), { requested_at = os.time(), source = 'in_game' })
    return ok, ok and { cancelled = true } or nil, ok and nil or 'cancel file failed'
  end
  return false, nil, 'unsupported command'
end

-- Writing to a signal that was removed meanwhile can crash the game natively.
local function ping_alive(store, ping)
  local alive = false
  pcall(function() alive = store:IsPingIDAlreadyRegistered(ping) == true end)
  return alive
end

local function admin_reply(ping_id, r)
  local store = find('UWEPingSystemComponent')
  if not store then log('admin reply: ping store not found'); return end
  if not ping_alive(store, ping_id) then log('admin reply: the signal is gone'); return end
  local ok, err = pcall(function()
    store:SetPingDisplayName(ping_id, FText(r.text))
    store:SetPingThumbnailColor(ping_id, r.ok and GREEN or RED)
  end)
  if not ok then log('admin reply failed: ' .. tostring(err)) end
end

-- After REPLY_SECONDS the signal gets back the name and colour it had before the command.
local function remember_restore(item)
  local key = guid_key(item.ping_id)
  local r = admin_restores[key]
  if r then r.at = os.time() + REPLY_SECONDS; return end
  local picked = admin_colors[key]
  admin_restores[key] = { ping = item.ping_id, name = item.old_name,
    color = picked and picked.color, at = os.time() + REPLY_SECONDS }
end

local function admin_restore_due()
  local now = os.time()
  for key, r in pairs(admin_restores) do
    if now >= r.at then
      admin_restores[key] = nil
      local store = find('UWEPingSystemComponent')
      if store and not ping_alive(store, r.ping) then
        log('admin reply over: the signal was removed meanwhile; nothing to restore')
      elseif store then
        local ok, err = pcall(function()
          if r.name then store:SetPingDisplayName(r.ping, FText(r.name)) end
          if r.color then store:SetPingThumbnailColor(r.ping, r.color) end
        end)
        log(string.format('admin reply over: name %s, colour %s%s',
          r.name and ('restored to ' .. r.name) or 'unknown, left as the answer',
          r.color and 'restored' or 'unknown, left', ok and '' or (' (failed: ' .. tostring(err) .. ')')))
      end
    end
  end
  for key, c in pairs(admin_colors) do
    if now - c.at > 30 then admin_colors[key] = nil end
  end
end

-- One queued command per call, at most one per admin_gap_s (admin_pace.lua).
local function admin_drain()
  local item = admin_pace.take(admin_queue, os.time())
  if item then
    local sender = item.sender
    local r = admin_signal.run(ADMIN, sender, item.text, { now = os.time, call = admin_call })
    if r and r.silent then
      if r.log then
        log(string.format('admin: ignored %s from %s (eos %s): not an admin', item.text,
          tostring(sender.name), tostring(sender.eos)))
      end
    end
    if r and not r.silent then
      log(string.format('admin command: sender=%s eos=%s command=%s result=%s %s',
        tostring(sender.name), tostring(sender.eos), item.text, r.ok and 'done' or 'refused', r.text))
      admin_reply(item.ping_id, r)
      remember_restore(item)
      admin_pace.mark(admin_queue, os.time())
    end
  end
  admin_restore_due()
end

-- RegisterHook must run on the game thread on UE4SS 1190; retried until the function has loaded.
LoopAsync(5000, function()
  if admin_hooked and color_hooked then return true end
  ExecuteInGameThread(function()
    if not admin_hooked then
      local fn = StaticFindObject(ADMIN_HOOK)
      if fn and fn:IsValid() then
        RegisterHook(ADMIN_HOOK, function(Context, PingId, NewName)
          local text, ping_id, old
          pcall(function() text = NewName:get():ToString() end)
          if type(text) ~= 'string' then return end
          if text:sub(1, #ADMIN.prefix) ~= ADMIN.prefix then
            pcall(function() admin_restores[guid_key(PingId:get())] = nil end)
            return
          end
          pcall(function() ping_id = guid_copy(PingId:get()) end)
          if not ping_id then return end
          pcall(function() old = find('UWEPingSystemComponent'):GetPingDisplayName({}, PingId:get()):ToString() end)
          if type(old) ~= 'string' or old == '' or old:sub(1, #ADMIN.prefix) == ADMIN.prefix then old = nil end
          local sender = admin_identity(Context:get())
          local entry = { sender = sender, ping_id = ping_id, text = text, old_name = old }
          local who = tostring(sender.eos or sender.name or sender.connection)
          local queued, why = admin_pace.push(admin_queue, entry, who)
          if not queued then
            log(string.format('admin: %s from %s not queued: %s (%d waiting)', text, tostring(sender.name), why,
              admin_pace.size(admin_queue)))
            local busy = why == 'sender_busy' and 'Busy: your earlier commands are still waiting'
              or 'Busy: too many commands waiting, try again in a minute'
            admin_reply(ping_id, { ok = false, text = busy })
          end
        end)
        admin_hooked = true
        log('admin signal hook registered on game thread')
      end
    end
    if not color_hooked then
      local fn = StaticFindObject(COLOR_HOOK)
      if fn and fn:IsValid() then
        -- EDIT sends the colour right after the name: that colour is the one to give back.
        RegisterHook(COLOR_HOOK, function(_, PingId, Color)
          pcall(function()
            admin_colors[guid_key(PingId:get())] = { color = color_copy(Color:get()), at = os.time() }
          end)
        end)
        color_hooked = true
        log('admin colour hook registered on game thread')
      end
    end
  end)
  return admin_hooked and color_hooked
end)

-- The game itself carries a cheat line from any client to the server through this call, and runs it
-- with no check; a client mod that shows the game's hidden cheat panel is enough to send one. Here the
-- line is emptied before the game runs it, for everyone. An admin's line then runs as it is unless the
-- console's deny list names it, or as a console line when it starts with the console's word; anyone
-- else's is dropped and logged.
local CHEAT_HOOK = '/Script/Subnautica2.SN2PlayerController:ServerCheat'
local cheat_hooked = false
local function controller_identity(pc)
  local name, connection
  pcall(function() name = ps_name(pc.PlayerState) end)
  pcall(function() connection = pc.NetConnection:GetFName():ToString() end)
  return { name = name or '?', eos = admin_signal.connection_id(ADMIN, connection) }
end
LoopAsync(5000, function()
  if cheat_hooked then return true end
  ExecuteInGameThread(function()
    if cheat_hooked then return end
    local fn = StaticFindObject(CHEAT_HOOK)
    if not (fn and fn:IsValid()) then return end
    RegisterHook(CHEAT_HOOK, function(Context, Msg)
      local text
      pcall(function() text = Msg:get():ToString() end)
      local emptied = pcall(function() Msg:set('') end)
      local sender = controller_identity(Context:get())
      if not emptied then
        log(string.format('cheat gate: COULD NOT STOP a line from %s (eos %s): %s', sender.name,
          tostring(sender.eos), tostring(text)))
        return
      end
      if type(text) ~= 'string' or text == '' then return end
      if not admin_signal.authorized(ADMIN.admins, sender) then
        log(string.format('cheat gate: dropped %s from %s (eos %s): not an admin', text, sender.name,
          tostring(sender.eos)))
        return
      end
      log(string.format('cheat gate: %s from admin %s', text, sender.name))
      admin_call('mp', { sender = sender, line = text, forwarded = true })
    end)
    cheat_hooked = true
    log('cheat gate registered on ' .. CHEAT_HOOK)
  end)
  return cheat_hooked
end)

-- Empty-server policy (idle.lua): FreezeTime with nobody in, UnfreezeTime on a join, and an
-- optional stop request that the join watcher carries out.
local IDLE = idle.new({
  freeze_s = idle.seconds(os.getenv('SN2_IDLE_FREEZE_MINUTES') or '10', 60),
  stop_s = idle.seconds(os.getenv('SN2_IDLE_STOP_HOURS'), 3600),
})
local function idle_tick(st)
  if st.state ~= 'up' then return end
  local joiners = 0
  for _, p in ipairs(st.players or {}) do
    if p.name ~= st.host_name then joiners = joiners + 1 end
  end
  if state.daylight_frozen ~= nil then
    idle.hold(IDLE, state.daylight_frozen)
    state.daylight_frozen = nil
  end
  for _, act in ipairs(idle.tick(IDLE, joiners, os.time())) do
    local host = controller_named(st.host_name)
    if act == 'freeze' and host then
      log('idle: nobody in for the freeze time; FreezeTime as the host')
      run_as(host, 'FreezeTime', st.host_name .. ' (idle freeze)')
    elseif act == 'unfreeze' and host then
      log('idle: a player joined; UnfreezeTime as the host')
      run_as(host, 'UnfreezeTime', st.host_name .. ' (idle unfreeze)')
    elseif act == 'stop' then
      log('idle: nobody in for IDLE_STOP_HOURS; asking the container to stop the game')
      write_atomic(cpath('idle-stop-request.json'), { ts = os.time(), reason = 'idle_stop_hours' })
    end
  end
end

-- Saving (save_policy.lua): with SAVE_EVERY_MINUTES set, the game's own 2-minute autosave is
-- switched off and the host saves every N minutes and once after each batch of leavers.
local SAVES = save_policy.new({ every_s = idle.seconds(os.getenv('SN2_SAVE_EVERY_MINUTES') or '10', 60) })
local GAME_LOG = os.getenv('SN2_GAME_LOG_WIN')
local game_log_pos = nil
-- autosave_completed lines the game log gained since the last call; complete lines only, and none
-- from before this mod started reading. A new, shorter log (a game restart) is read from its start.
local function new_autosaves()
  if not GAME_LOG then return 0 end
  local f = io.open(GAME_LOG, 'rb')
  if not f then return 0 end
  local size = f:seek('end') or 0
  if game_log_pos == nil then game_log_pos = size; f:close(); return 0 end
  if size < game_log_pos then game_log_pos = 0 end
  local n = 0
  if size > game_log_pos then
    local from = math.max(game_log_pos, size - 1048576)
    f:seek('set', from)
    local complete = (f:read(size - from) or ''):match('^(.*\n)') or ''
    for _ in complete:gmatch('autosave_completed') do n = n + 1 end
    game_log_pos = from + #complete
  end
  f:close()
  return n
end
local function save_tick(st)
  local names = {}
  for _, p in ipairs(st.players or {}) do
    if p.name and p.name ~= st.host_name then names[#names + 1] = p.name end
  end
  for _, act in ipairs(save_policy.tick(SAVES, os.time(), st.state == 'up', names, new_autosaves())) do
    if act == 'autosave_off' then
      local host = controller_named(st.host_name)
      if host then
        log('saves: the game autosaved; ToggleAutoSave as the host, the host saves on its own schedule')
        run_as(host, 'ToggleAutoSave', st.host_name .. ' (autosave off)')
      end
    elseif act == 'save' then
      local ok, _, err = handlers.save()
      if not ok then log('saves: scheduled save not requested: ' .. tostring(err)) end
    end
  end
end

-- The replay ledger survives a game restart; 1024 nonces outlast the 120 s acceptance window.
local NONCE_LEDGER = cpath('receipts', 'nonces.txt')
local remembered = {}
for id in (read_file(NONCE_LEDGER) or ''):gmatch('[0-9a-f]+') do remembered[#remembered + 1] = id end
while #remembered > 1024 do table.remove(remembered, 1) end
local seen = protocol.new_seen(remembered)
local function remember_nonce(id)
  remembered[#remembered + 1] = id
  while #remembered > 1024 do table.remove(remembered, 1) end
  local f = io.open(NONCE_LEDGER, 'wb')
  if f then f:write(table.concat(remembered, '\n') .. '\n'); f:close() end
end

local function list_inbox()
  local names = {}
  local p = io.popen('cmd /c dir /b "' .. cpath('inbox') .. '\\*.json" 2>nul')
  if not p then return names end
  for line in p:lines() do
    line = line:gsub('%s+$', '')
    if line:match('^[0-9a-f]+%.json$') then names[#names + 1] = line end
  end
  p:close()
  return names
end

local function regular_not_reparse(path)
  -- Wine's cmd has no reparse-point filter (-l matches nothing), so a link passes as a file;
  -- only the container's own user can write the inbox.
  local p = io.popen('cmd /c dir /a:-d /b "' .. path .. '" 2>nul')
  if not p then return false end
  local line = p:read('*l'); p:close()
  return line ~= nil
end

local inflight = {} -- nonces whose handler is queued on the game thread, answer not yet written
local function process_inbox()
  local pending = cpath('inbox', '.pending')
  if not read_file(pending) then return end
  os.remove(pending)
  for _, name in ipairs(list_inbox()) do
    local path = cpath('inbox', name)
    local is_regular = regular_not_reparse(path)
    local raw = is_regular and read_file(path) or nil
    os.remove(path)
    local id = name:gsub('%.json$', '')
    local result
    if not is_regular then
      result = answer(id, false, nil, 'non_regular_file')
    elseif not raw or #raw > protocol.MAX_BYTES then
      result = answer(id, false, nil, 'unreadable_or_too_large')
    elseif not protocol.valid_utf8(raw) then
      result = answer(id, false, nil, 'invalid_utf8')
    else
      local ok, msg = pcall(json.decode, raw)
      if not ok then
        result = answer(id, false, nil, 'bad_json')
      else
        local cmd, args = protocol.validate(msg, name, os.time(), CFG.enabled_set, seen)
        if not cmd then
          result = answer(id, false, nil, args)
        else
          remember_nonce(id)
          -- A UFunction called from this loop fails, so the handler runs on the game thread.
          inflight[id] = true
          ExecuteInGameThread(function()
            local hok, ret, data, err = pcall(handlers[cmd], args)
            local r
            if not hok then
              r = answer(id, false, nil, 'handler_error:' .. tostring(ret))
            else
              r = answer(id, ret, data, err)
            end
            local wok, werr = pcall(function()
              if protocol.valid_nonce(id) then write_atomic(cpath('outbox', name), r) end
            end)
            inflight[id] = nil
            if not wok then log('answer for ' .. cmd .. ' not written: ' .. tostring(werr)) end
          end)
        end
      end
    end
    if result and not inflight[id] and protocol.valid_nonce(id) then
      write_atomic(cpath('outbox', name), result)
    end
  end
  -- A ceiling for answers whose client died before reading them.
  local answers = {}
  local p = io.popen('cmd /c dir /b "' .. cpath('outbox') .. '\\*.json" 2>nul')
  if p then for line in p:lines() do answers[#answers + 1] = line:gsub('%s+$', '') end; p:close() end
  table.sort(answers)
  while #answers > 128 do os.remove(cpath('outbox', table.remove(answers, 1))) end
end

-- After a crash: drop the mod's unpublished temp files and answer whatever is still in the inbox.
os.execute('cmd /c del /q "' .. cpath('tmp', 'mod-*.json') .. '" 2>nul')
if #list_inbox() > 0 then
  local f = io.open(cpath('inbox', '.pending'), 'wb'); if f then f:close() end
end

-- Launch-cinematic join hold (cinematic_hold.lua): while Gamestate.LifepodAscending is set in the
-- game log, the limit is the players already in.
local hold = require('cinematic_hold')
local LIFEPOD_JOIN_HOLD = (os.getenv('SN2_LIFEPOD_JOIN_HOLD') or 'true') ~= 'false'
local HOLD = hold.new()
local HOLD_LOG = os.getenv('SN2_GAME_LOG_WIN') or '..\\..\\Saved\\Logs\\Subnautica2.log'
local hold_pos, hold_buf = nil, ''
local function world_limit(cap)
  local sub, gm, gs = find('UWEOnlineSessionSubsystem'), find('BP_ClientLobbyGameMode_C'), find('GameSession')
  set_limits(sub, gm, cap)
  local back
  if gs then
    pcall(function() gs.MaxPlayers = cap end)
    pcall(function() back = gs.MaxPlayers end)
  end
  return back
end
local cached_players
local function hold_act(acts)
  for _, a in ipairs(acts) do
    if a[1] == 'close' then
      local n = hold.hold_limit(#cached_players())
      log(string.format('join hold: %s; joins held, limit %d (world MaxPlayers=%s)',
        a[2], n, tostring(world_limit(n))))
    else
      local cap = CFG.host.max_players
      log(string.format('join hold: %s at %s UTC; joins proceed, limit %d (world MaxPlayers=%s)',
        a[2], os.date('!%H:%M:%S'), cap, tostring(world_limit(cap))))
    end
  end
end
local hold_log_said, poll_said = nil, {}
local roster_rows = {}
local function refresh_roster()
  local live = status.live_players(to_str)
  local paths, rows, controllers = {}, {}, {}
  for _, p in ipairs(live) do
    paths[#paths + 1] = p.path
    rows[#rows + 1] = { name = p.name, ping_ms = p.ping_ms }
  end
  local ok, all = pcall(FindAllOf, 'PlayerController')
  if ok and all then
    for _, pc in ipairs(all) do
      if valid(pc) then
        local name, path
        pcall(function() name = ps_name(pc.PlayerState); path = object_path(pc) end)
        if name and path then controllers[name] = path end
      end
    end
  end
  roster_rows = rows
  host_core.set_controller_cache(controllers)
  return paths
end
cached_players = function() return roster_rows end
local function hold_poll()
  local f, why = io.open(HOLD_LOG, 'rb')
  if not f then
    ADMIN.ids = {} -- no log, no way to know who is on which connection
    if hold_log_said ~= tostring(why) then
      hold_log_said = tostring(why)
      log('join hold: cannot read the game log ' .. HOLD_LOG .. ' (' .. tostring(why) ..
        '); holds and live unlock sharing are off until it opens')
    end
    return
  end
  if hold_log_said then log('join hold: the game log opened again'); hold_log_said = nil end
  local size = f:seek('end')
  if not hold_pos or size < hold_pos then hold_pos = size; ADMIN.ids = {} end -- start at the end; a new log restarts
  f:seek('set', hold_pos)
  local chunk = f:read('a') or ''
  f:close()
  hold_pos = hold_pos + #chunk
  local lines
  lines, hold_buf = hold.split_new(hold_buf, chunk)
  for _, l in ipairs(lines) do
    admin_signal.note_connection(ADMIN, l)
    local player, id = admin_signal.login_label(l)
    if player then log('player ' .. player .. ' eos=' .. id); EOS_BY_NAME[player] = id end -- the value ADMINS takes
    if LIFEPOD_JOIN_HOLD then hold_act(hold.line(HOLD, l, os.time())) end
    if UNLOCK_REPLAY_ENABLED then pcall(unlock_line, l) end
  end
  if LIFEPOD_JOIN_HOLD then hold_act(hold.tick(HOLD, os.time())) end
end
local function said_once(what, err)
  local key = what .. '\0' .. tostring(err)
  if not poll_said[key] then poll_said[key] = true; log(what .. ' error: ' .. tostring(err)) end
end
local no_controller_said = {}
local banned_seen = {}
local function hosted_replay()
  local ok, err = pcall(function()
    access.tick(banned_seen, access.names(read_file(cpath('bans.txt'))), cached_players(), HOST_NAME,
      function(name)
        local ran, _, why = handlers.player({ player = HOST_NAME, command = 'KickPlayer ' .. name })
        return ran, why
      end, log)
    local named = player_names()
    local reachable = {}
    for _, n in ipairs(named) do reachable[n] = true end
    for _, p in ipairs(cached_players()) do
      if p.name ~= HOST_NAME and not reachable[p.name] and not no_controller_said[p.name] then
        no_controller_said[p.name] = true
        log('unlocks: player ' .. tostring(p.name) .. ' is listed but has no controller by that name; no replay')
      end
    end
    if UNLOCK_REPLAY_ENABLED then unlocks.joins(UNLOCKS, UNLOCK_GAME, named, HOST_NAME) end
  end)
  if not ok then said_once('join replay', err) end
end
local HOSTED_GATE = hosted_poll_gate.new({
  safety_s = 60,
  now = os.time,
  valid = valid,
  find = function(path)
    local o
    pcall(function() o = StaticFindObject(path) end)
    return o
  end,
  hold = function()
    local ok, err = pcall(hold_poll)
    if not ok then said_once('join hold', err) end
  end,
  refresh = refresh_roster,
  replay = hosted_replay,
})
local function hosted_poll() hosted_poll_gate.tick(HOSTED_GATE) end

math.randomseed(os.time())
log('loaded; control dir ' .. DIR)
LoopAsync(CFG.poll_ms, function()
  local ok, err = pcall(function()
    ExecuteInGameThread(admin_drain)
    local notice_raw = read_file(cpath('notify-request.json'))
    if notice_raw then
      os.remove(cpath('notify-request.json'))
      local notice = json.decode(notice_raw)
      ExecuteInGameThread(function()
        local ok, err = pcall(function()
          local notice_players, names = notify.targets(status.live_players(to_str), HOST_NAME, notice.players)
          local game = { find = StaticFindObject, world = function() return notice_players[1] end,
            log = log, text = FText }
          notify.send(game, notice_players, notice.kind == 'warning' and 'warning' or 'info',
            notice.header or notice.text, notice.text, notice.duration)
          for _, name in ipairs(names) do
            local controller = controller_named(name)
            if controller then
              pcall(function() controller:ClientMessage(notice.header or notice.text, FName('None'), 0.0) end)
            end
          end
        end)
        if not ok then log('notification callback failed: ' .. tostring(err)) end
      end)
    end
    if _G.SN2_HOSTED then
      ExecuteInGameThread(function()
        -- Built before anyone joins, so the first join pays nothing.
        if UNLOCK_REPLAY_ENABLED and not state.asset_index_primed then
          state.asset_index_primed = true
          asset_index()
        end
        hosted_poll()
      end)
    end
    write_atomic(cpath('readiness.json'), { ts = os.time(), hosted = _G.SN2_HOSTED == true,
      armed = read_file(cpath('HOST_ARMED')) ~= nil })
    process_inbox()
  end)
  if not ok then log('loop error: ' .. tostring(err)) end
  return false
end)

-- status.json, read by the Discord card, the viewer status line and the map card.
local STATUS_MS = 30000
-- The world clock: UWESkyActor answers a fraction of the day, the engine's actors answer hours.
local CLOCK_CLASSES = {
  { cls = 'UWESkyActor', unit = 'fraction' },
  { cls = 'SunMoonDaySequenceActor', unit = 'hours' },
  { cls = 'DaySequenceActor', unit = 'hours' },
  { cls = 'BaseDaySequenceActor', unit = 'hours' },
}
local clock_said = false
local clock_source_said = false
local function clock_value(a)
  local t
  pcall(function() t = a:GetTimeOfDay() end)
  if type(t) ~= 'number' then pcall(function() t = a.TimeOfDay end) end
  if type(t) ~= 'number' or t ~= t or t == math.huge or t == -math.huge then return nil end
  return t
end
local function time_of_day()
  local t, from, unit
  for _, c in ipairs(CLOCK_CLASSES) do
    pcall(function()
      local a = FindFirstOf(c.cls)
      if valid(a) then t = clock_value(a); from = c.cls; unit = c.unit end
    end)
    if t then break end
  end
  if not t then
    pcall(function()
      local s = FindFirstOf('DaySequenceSubsystem')
      if valid(s) then
        local a = s:GetDaySequenceActor(true) -- GetDaySequenceActor(bool bFindFallbackOnNull)
        if valid(a) then t = clock_value(a); from = 'DaySequenceSubsystem'; unit = 'hours' end
      end
    end)
  end
  if t and not clock_source_said then
    clock_source_said = true
    log('time of day: read off ' .. from .. ' (' .. unit .. ')')
  end
  if t then
    local frac = unit == 'fraction' and t or (t / 24)
    frac = frac - math.floor(frac)
    local minutes = math.floor(frac * 24 * 60 + 0.5) % (24 * 60)
    return string.format('%02d:%02d', minutes // 60, minutes % 60), math.floor(frac * 1000 + 0.5) / 1000
  end
  -- No clock: log once which loaded classes are named like one (names only, nothing called).
  if not clock_said and _G.SN2_HOSTED then
    clock_said = true
    local names, named, n = {}, {}, 0
    pcall(function()
      ForEachUObject(function(o)
        local cn
        pcall(function() cn = o:GetClass():GetFName():ToString() end)
        if cn and not named[cn] and not cn:match('Texture') and not cn:match('Material') and not cn:match('Volume')
          and (cn:match('[Dd]ay') or cn:match('[Tt]ime[Oo]f') or cn:match('[Ww]eather') or cn:match('[Cc]lock')
            or cn:match('[Ss]ky') or cn:match('[Ss]un[A-Z_]') or cn:match('[Nn]ight')) then
          named[cn] = true; n = n + 1
          if n <= 60 then names[#names + 1] = cn end
        end
      end)
    end)
    local tried = {}
    for _, c in ipairs(CLOCK_CLASSES) do tried[#tried + 1] = c.cls end
    log('time of day: no clock actor under ' .. table.concat(tried, ', ') .. '; ' .. n
      .. ' loaded classes named like one: ' .. table.concat(names, ', '))
  end
  return nil
end
_G.SN2_TIME_OF_DAY = time_of_day -- read by tests/lua/host_behaviour_spec.lua

-- The current weather and the loaded weather types, which are what SetCurrentWeather takes.
local function object_name(o)
  local n
  pcall(function() n = o:GetFName():ToString() end)
  if type(n) ~= 'string' or n == '' then pcall(function() n = to_str(o.Name) end) end
  return type(n) == 'string' and n ~= '' and n or nil
end
local weather_paths_said = false
local function weather()
  local current, types = nil, {}
  pcall(function()
    local sync = FindFirstOf('UWEWeatherSyncComponent')
    if valid(sync) then
      local w = sync:GetCurrentWeather()
      if valid(w) then current = object_name(w) end
    end
  end)
  local paths = {}
  pcall(function()
    local named = {}
    for _, t in ipairs(FindAllOf('UWEWeatherTypeBase') or {}) do
      local n = valid(t) and object_name(t) or nil
      if n and not named[n] and not n:match('^Default__') then
        named[n] = true; types[#types + 1] = n
        pcall(function() paths[n] = t:GetFullName() end)
      end
    end
  end)
  table.sort(types)
  if #types > 0 and not weather_paths_said then
    weather_paths_said = true
    local parts = {}
    for _, n in ipairs(types) do parts[#parts + 1] = n .. '=' .. tostring(paths[n]) end
    log('weather types: ' .. table.concat(parts, '; '))
  end
  return current, types
end
_G.SN2_WEATHER = weather -- read by tests/lua/host_behaviour_spec.lua

-- The console's weather commands moved nothing; the sync component's SetCurrentWeather does.
-- Called on the game thread already.
set_weather = function(name)
  local ok, err = pcall(function()
    local sync = FindFirstOf('UWEWeatherSyncComponent')
    if not valid(sync) then error('no weather sync component', 0) end
    local target
    for _, t in ipairs(FindAllOf('UWEWeatherTypeBase') or {}) do
      if valid(t) and object_name(t) == name then target = t; break end
    end
    if not target then error('no loaded weather type named ' .. name, 0) end
    sync:SetCurrentWeather(target)
  end)
  log('weather ' .. name .. (ok and ' set through the sync component' or (': ' .. tostring(err))))
  if ok then return true end
  return false, tostring(err)
end
_G.SN2_SET_WEATHER = set_weather -- read by tests/lua/host_behaviour_spec.lua

-- The per-key settings block, judged against the latest submission; only a status write
-- (which passes `now`) marks `verified_at`.
settings_block = function(tod, wx, now)
  local s = state.settings
  if not s then return nil end
  local obs = { time_of_day = tod, daylight = IDLE.frozen and 'frozen' or 'normal', weather = wx }
  return settings.status_block(s.plan, s.track, obs, now)
end
settings_readback = function() return time_of_day(), (weather()) end
local function current_map()
  local m
  pcall(function() m = to_str(FindFirstOf('World'):GetFName()) end)
  return m
end

-- Private voice-range signals in the game's saved signal store, visible to one listener only.
local VOICE_WARN = (os.getenv('SN2_VOICE_WARN') or 'true') ~= 'false'
local VOICE = voice_range.new({
  range_m = tonumber(os.getenv('SN2_VOICE_RANGE_M') or '') or voice_range.DEFAULT_RANGE_M,
  host = HOST_NAME,
})
local voice_ping_error
local function ping_store()
  local component = saved_ping_store()
  if not component then return nil end
  local store = {}
  function store.add(_, listener, target, label, pos, color)
    local pawn = target.player and target.player.PawnPrivate or nil
    if not valid(pawn) then return nil end
    local id, err = add_location_ping(component, label,
      { X = pos.x, Y = pos.y, Z = pos.z }, pawn, color)
    if not id then
      if voice_ping_error ~= tostring(err) then
        voice_ping_error = tostring(err)
        log('voice range: signal add failed: ' .. voice_ping_error)
      end
      return nil
    end
    component:SetDefaultPingVisibility(id, false)
    component:SetPingVisibilityForPlayer(listener.player, id, true)
    return id
  end
  function store.move(_, id, pos)
    local ok, err = pcall(function()
      component:SetPingLocation(id, { X = pos.x, Y = pos.y, Z = pos.z })
    end)
    if not ok and voice_ping_error ~= tostring(err) then
      voice_ping_error = tostring(err); log('voice range: signal move failed: ' .. voice_ping_error)
    end
  end
  function store.remove(_, id)
    local ok, err = pcall(function() component:RemovePing(id) end)
    if not ok and voice_ping_error ~= tostring(err) then
      voice_ping_error = tostring(err); log('voice range: signal removal failed: ' .. voice_ping_error)
    end
  end
  return store
end

pcall(function()
  NotifyOnNewObject('/Script/Engine.PlayerState', function()
    hosted_poll_gate.mark_dirty(HOSTED_GATE)
    status.invalidate()
  end)
end)
if VOICE_WARN then
  LoopAsync(2000, function()
    ExecuteInGameThread(function()
      local ok, err = pcall(function()
        local store = ping_store()
        if store then voice_range.update(VOICE, status.live_players(to_str, current_map()), store) end
      end)
      if not ok then log('voice range error: ' .. tostring(err)) end
    end)
    return false
  end)
else
  log('voice range warnings are off')
end
LoopAsync(STATUS_MS, function()
  ExecuteInGameThread(function()
    local ok, err = pcall(function()
      if _G.SN2_CHECK_HOST_BODY then _G.SN2_CHECK_HOST_BODY() end
      local map = current_map()
      local tod, frac = time_of_day()
      local wx, wxt = weather()
      local st = status.build({
        state = (_G.SN2_HOSTED and map and map:find('Main')) and 'up' or 'lobby',
        map = map,
        branch = os.getenv('SN2_STEAM_BRANCH') or 'unknown',
        save = state.save or os.getenv('SN2_SAVE_NAME') or 'newest',
        player_slots = state.player_slots or tonumber(os.getenv('SN2_PLAYER_SLOTS') or '') or 4,
        host_name = HOST_NAME,
        time_of_day = tod, day_fraction = frac,
        weather = wx, weather_types = wxt,
      }, to_str)
      idle_tick(st)
      save_tick(st)
      st.clock_frozen = IDLE.frozen
      if HOLD.held then st.join_hold = hold.NOTICE end
      if state.friend_code then st.sonar_code = state.friend_code end
      if _G.SN2_HOSTED and not state.settings_loaded then
        state.settings_loaded = true
        pcall(apply_settings, 'armed')
      end
      st.settings = settings_block(tod, wx, os.date('!%Y-%m-%dT%H:%M:%SZ'))
      st.unlocks = unlocks.snapshot(UNLOCKS)
      write_atomic(cpath('status.json'), st)
    end)
    if not ok then log('status error: ' .. tostring(err)) end
  end)
  return false
end)
