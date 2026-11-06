-- recipe.lua: what the container adds to SN2SlotFreeHost, loaded from its
-- main.lua: the moonpool file-drop queue, status.json, the idle freeze, the
-- slots and player commands. Hosting, the host prune and
-- the story-goal unlock stay in main.lua as written. Original code, MIT.
-- What nothing else provides: a socket-free control queue and a status file
-- read by the Discord card; no community mod exposes either.
local json = require('json')
local protocol = require('protocol')
local status = require('status')
local host_core = require('sn2_host_core')
local controller_named = host_core.controller_named
local idle = require('idle')
local access = require('access')
local voice_range = require('voice_range')
local sky = require('sky')
local notify = require('notify')
local hosted_poll_gate = require('hosted_poll')
-- Per-module switches, so one module at a time can be turned off when the host misbehaves.
-- Off means not registered or not run at all, never half-run.
-- true: the clock settings go straight to UWESkyActor (no notice for players). Off by
-- default: the console fallback is the proven path.
local SKY_CLOCK = os.getenv('SN2_SKY_CLOCK') == 'true'

local log = host_core.log
-- GetFullName() is "<Class> <path>"; StaticFindObject takes the path alone. Every proven lookup
-- here passes a bare path; a full name (with the class in front) would not find its object.
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
  host = {
    save_slot = 'Slot1',
    max_players = 4,
  },
  enabled_commands = { 'status', 'players', 'host', 'receipt', 'kick', 'slots',
    'friend_code' },
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

-- The operator's file is copied from config.example.json on the first start
-- and kept, so a list the example shipped is not the operator's choice: on a
-- host first started under an older release it keeps every newer command
-- refused as disabled_by_config (unlocks,
-- waypoint and settings all refused). A file list equal to any list the
-- example ever carried gives way to the default and is said once; any other
-- list is the operator's own and is kept as set. The example carries no
-- list now; these are the ones it did.
local EXAMPLE_LISTS = {
  'status,players,host,receipt,player',
  'status,players,host,receipt,player,bring',
  'status,players,host,receipt,player,bring,slots',
  'status,players,host,receipt,player,bring,slots,unlocks',
  'status,players,host,receipt,player,bring,slots,unlocks,waypoint',
  'status,players,host,receipt,player,bring,slots,unlocks,waypoint,settings',
}
local function is_example_list(list)
  if type(list) ~= 'table' then return false end
  local key = table.concat(list, ',')
  for _, l in ipairs(EXAMPLE_LISTS) do if l == key then return true end end
  return false
end
_G.SN2_IS_EXAMPLE_LIST = is_example_list -- read by tests/lua/host_mod_spec.lua

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
      if is_example_list(parsed.enabled_commands) then
        log(string.format('config.json enabled_commands is an older example list (%d of %d); using the full list. '
          .. 'Set your own list to restrict commands.', #parsed.enabled_commands, #DEFAULTS.enabled_commands))
        parsed.enabled_commands = nil
      end
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
-- PLAYER_SLOTS + 1 from the launcher: the host account holds a player slot
-- (measured: GetNumPlayers 2 with one joiner).
local env_limit = tonumber(os.getenv('SN2_SESSION_LIMIT') or '')
if env_limit and env_limit >= 2 and env_limit <= 64 then CFG.host.max_players = env_limit end
-- The launcher exports SN2_CONTROL_WIN; config.json may override it.
local DIR = os.getenv('SN2_CONTROL_WIN') or CFG.control_dir
if CFG.control_dir ~= DEFAULTS.control_dir then DIR = CFG.control_dir end
host_core.configure({ dir = DIR })
local cpath = host_core.cpath

-- Atomic write: temp file in control\tmp, then rename into place.
local function write_atomic(dest, tbl)
  local tmp = cpath('tmp', 'mod-' .. tostring(os.time()) .. '-' .. tostring(math.random(1, 1e9)) .. '.json')
  local encoded = json.encode(tbl)
  if dest:find('\\outbox\\', 1, true) and #encoded > protocol.MAX_RESPONSE_BYTES then
    local id = dest:match('\\([0-9a-f]+)%.json$') or ''
    encoded = json.encode(protocol.result(id, false, {}, 'response_too_large',
      os.getenv('SN2_GAME_BUILD_ID') or 'unknown'))
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

local state = {
  started = os.time(),
  checks = {},
  details = {},
  host_attempted = false,
  host_result = nil,
}
-- Player limits are IntProperty on both objects: the subsystem's
-- MaxSessionPlayerCount and the lobby game mode's GameSession.MaxPlayers.
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

-- Save slot: an explicit name (moonpool host <save>, SAVE_NAME) wins; else the
-- newest <name>.sav in the save folder; else the configured new-world slot.
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
-- main.lua's Host call asks this for its SaveSlot (it falls back to "Slot1").
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
  -- Hosting is SN2SlotFreeHost's own armed one-shot; moonpool arm writes HOST_ARMED.
  host = function() return false, nil, 'use_moonpool_arm' end,
  receipt = function()
    return true, { checks = state.checks, details = state.details, host_attempted = state.host_attempted,
      hosted = _G.SN2_HOSTED == true, player_slots = state.player_slots, uptime_s = os.time() - state.started,
      limits = read_limits(find('UWEOnlineSessionSubsystem'), find('BP_ClientLobbyGameMode_C')) }
  end,
  save = function() return false, nil, 'not_implemented' end,
}
_G.SN2_HANDLERS = handlers -- read by tests/lua/host_behaviour_spec.lua
-- Player services ------------------------------------------------------------
-- The game's own command class (BP_SN2CheatManager_C) hangs off every player
-- controller; KismetSystemLibrary:ExecuteConsoleCommand(World, Command,
-- SpecificPlayer) runs a console line as that player, server-side
-- (PLAYER_SERVICES.md). The game's reply lines go to its own log.

handlers.save = function()
  local pc = controller_named(os.getenv('SN2_HOST_NAME') or 'SN2 Host')
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
  return handlers.player({ player = os.getenv('SN2_HOST_NAME') or 'SN2 Host', command = 'KickPlayer ' .. args.player })
end

-- Server settings (settings.lua): moonpool copies the operator's settings.yaml
-- into the control folder; the mod reads it once hosted and on `moonpool
-- settings apply`. Only a key with a verified command runs, as the host's own
-- controller; every other key is logged and shown as "no verified command".
local settings = require('settings')
local set_weather -- defined beside the weather readback below
local settings_block, settings_readback -- defined beside the readbacks below
local function apply_clock(key, value, fallback_pc, fallback_line, why)
  local actor, ok, err
  if SKY_CLOCK then
    pcall(function() actor = FindFirstOf('UWESkyActor') end)
    ok, err = sky.apply(valid(actor) and actor or nil, key, value)
  else
    ok, err = false, 'switched off by SN2_SKY_CLOCK=false'
  end
  if ok then
    log(string.format('%s: %s=%s through UWESkyActor', why, key, value))
    return true, false
  end
  log(string.format('%s: UWESkyActor path failed (%s); using logged console fallback', why, tostring(err)))
  if not fallback_pc then return false, false, err end
  run_as(fallback_pc, fallback_line, why .. ' fallback')
  return true, true
end
local function apply_settings(why)
  local cfg, err = settings.parse(read_file(cpath('settings.yaml')))
  if not cfg then
    log('settings (' .. why .. '): ' .. err)
    state.settings = nil
    return nil, err
  end
  local p = settings.plan(cfg)
  local host_pc = #p.apply > 0 and controller_named(os.getenv('SN2_HOST_NAME') or 'SN2 Host') or nil
  -- What the card shows as applied is what ran: a console line needs the
  -- host's controller, the weather call needs a loaded type of that name.
  local ran = {}
  for _, a in ipairs(p.apply) do
    if a.key == 'weather' then
      local ok, miss = set_weather(a.line)
      if ok then
        ran[#ran + 1] = a
      else
        p.refused[#p.refused + 1] = { key = a.key, value = a.value, desired = a.desired, reason = miss }
      end
    elseif a.key == 'time_of_day' or a.key == 'daylight' then
      local ok, _, miss = apply_clock(a.key, a.value, host_pc, a.line, 'settings ' .. a.key)
      -- The idle freeze owns the clock while nobody is in and unfreezes on a
      -- join only from its own flag, so a daylight line hands it the state it
      -- just set (idle_tick reads this once).
      if ok then
        if a.key == 'daylight' then state.daylight_frozen = (a.line == 'FreezeTime') end
        ran[#ran + 1] = a
      else
        p.refused[#p.refused + 1] = { key = a.key, value = a.value, desired = a.desired, reason = miss }
      end
    elseif host_pc then
      run_as(host_pc, a.line, 'settings ' .. a.key)
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
  log(string.format('settings (%s): %d applied, %d refused, %d mods listed',
    why, #p.apply, #p.refused, #p.mods))
  -- The latest submission: every status write judges the readbacks against
  -- it (settings_block) and nothing applies it again.
  state.settings = { plan = p, track = settings.submission(p) }
  return p
end
-- The answer separates what was asked, what ran, what was refused and why,
-- and what the readbacks show now; the per-key block and the card's older
-- rows ride beside them. The answer's look marks nothing: `verified_at` is
-- set by a status write.
handlers.settings = function()
  local p, err = apply_settings('moonpool')
  if not p then return false, nil, err end
  local block = settings_block(settings_readback())
  local a = { requested = {}, submitted = {}, refused = {}, observed = {}, settings = {},
    values = block.values, mods = block.mods }
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



-- The game's saved signal store (UWEPingSystemComponent) and one location ping
-- in it. Shared by every feature that shows a player a signal; the caller
-- chooses the colour.
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
  -- UWEPingSystem.hpp:124; UE4SS LuaUObject.cpp updates an FStructProperty
  -- out parameter in the same table supplied by Lua.
  store:AddPing(pos, FText(name), data, 0.0, nil, tracking, out,
    false, tracking ~= nil, color)
  return out
end

-- moonpool friend-code (EXPERIMENTAL): ask the game's Friends view model for the
-- Sonar code and keep it for status.json. Every game call stays in the game
-- thread; only a string comes back out. The view model is the one the game made
-- for its open Friends screen, found again on every tick (friend_code.lua says
-- why one is never constructed here).
local friend_code = require('friend_code')
local SONAR_FILE = cpath('sonar-code.txt')
local FRIENDS_SCREEN = '/Game/Blueprints/UI/Friends/WBP_InGameFriends.WBP_InGameFriends_C'
-- The signed-in hosting account (launch-headless.sh); the code is that account's,
-- so a volume signed in to another account never shows the old one's code.
local HOST_SID = os.getenv('SN2_HOST_STEAMID') or ''
do -- the last code the game made survives a restart of the host
  local kept, sid = (read_file(SONAR_FILE) or ''):match('^%s*(%S+)%s+(%d+)%s*$')
  if HOST_SID ~= '' and sid == HOST_SID and friend_code.is_code(kept) then state.friend_code = kept end
end
local FC_GAME = {
  find_vm = function() local v = FindFirstOf('SN2InGameFriendScreenViewModel'); return valid(v) and v or nil end,
  others = function()
    local host, n = os.getenv('SN2_HOST_NAME') or 'SN2 Host', 0
    for _, p in ipairs(players()) do if p.name ~= host then n = n + 1 end end
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
  -- No screen to click on a headless host, so the screen a click would open is built the
  -- game's own way: its widget, made for the host's player controller and added to the
  -- viewport. The widget makes and owns the view model. Closed again by close_screen.
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
    -- done lives outside the loop: the game-thread poll sets it after the loop's own return,
    -- so the next round ends the loop instead of polling and logging the code again.
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

-- Shared unlocks (unlock_replay.lua says why): a host-side "Unlocked story
-- goal DA_BasePiece_*" or "DA_Tools_*" is sent as the command class's
-- `Unlock <form>` to every connected non-host player; a joiner gets the
-- starter set plus everything the host unlocked, as ONE batch. The set lives
-- in status.json, keyed by the save.
local unlocks = require('unlock_replay')
local UNLOCK_REPLAY_ENABLED = (os.getenv('SN2_UNLOCK_REPLAY') or 'true') ~= 'false'
local HOST_NAME = os.getenv('SN2_HOST_NAME') or 'SN2 Host'
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
  -- One batch: every line for one player in one pass, one controller lookup
  -- (176 lines in one command file ran in 4 s; one line per file took 30 s).
  -- Lines are spaced `interval` ms apart (UNLOCK_INTERVAL_MS, default 50): a
  -- A 20 ms burst froze the client's toolbar. Each line runs
  -- on the game thread; the controller is checked before every line.
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
  -- The join clock (ms, 1 s resolution) and "has a body" for the pre-control
  -- send: the batch goes out 2 s after the first poll that sees the pawn.
  now = function() return os.time() * 1000 end,
  -- The body is read off the PlayerState's PawnPrivate, the check main.lua's
  -- lifepod step was proven live with a real player body; the
  -- controller's Pawn is the second try.
  has_body = function(player)
    local pc = controller_named(player)
    local b = false
    if pc then
      pcall(function() local pw = pc.PlayerState.PawnPrivate; b = pw ~= nil and pw:IsValid() end)
      if not b then pcall(function() b = valid(pc.Pawn) end) end
    end
    return b
  end,
  -- Names-only lookup: an asset already loaded under that short name. Names
  -- compare without case (FName), so the object's own spelling is returned
  -- (DA_FlashLight_ItemType for a lookup of DA_Flashlight_ItemType). Answered
  -- from the asset index below, never a FindObject per name: each of those
  -- walked the whole object array on the game thread.
  exists = function(name)
    local idx = asset_index()
    return idx and idx.names[tostring(name):lower()] or false
  end,
  log = log,
}
-- The join replay's lookups, from ONE FindAllOf('DataAsset'): UE4SS filters it in
-- C++ and it includes subclasses, so it returns every scan data, item type,
-- recipe, construct data and story goal asset. names: lowercase short name ->
-- the game's own spelling, for exists(); scans: display name -> its *_ScanData
-- assets. Before, a Lua ForEachUObject over every object built the scan index
-- and every candidate name ran a FindObject that walked the object array again;
-- one join froze the game thread for 47-67 s, Epic's services dropped the
-- lobby, and UE4SS crashed. Data assets load with the world and
-- stay loaded; on a scan miss the index is rebuilt at most once a minute.
local ASSET_INDEX, ASSET_INDEX_AT = nil, -60
local function build_asset_index()
  local idx, names, scans = { names = {}, scans = {} }, 0, 0
  local started = os.clock()
  local ok, all = pcall(FindAllOf, 'DataAsset')
  for _, o in ipairs(ok and type(all) == 'table' and all or {}) do
    local short; pcall(function() short = o:GetFName():ToString() end)
    if type(short) == 'string' and short ~= '' then
      local k = short:lower()
      if not idx.names[k] then idx.names[k] = short; names = names + 1 end
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
_G.SN2_UNLOCK_GAME = UNLOCK_GAME -- read by tests/lua/host_behaviour_spec.lua
_G.SN2_ASSET_INDEX_RESET = function() ASSET_INDEX, ASSET_INDEX_AT = nil, -60 end -- tests only
-- Named players whose controller exists: a PlayerState seen before its
-- controller is not counted yet, so a joiner is replayed to only once the
-- Unlock lines can run as them.
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

-- moonpool slots N: the live limit, no re-host. Writes the lobby subsystem's
-- MaxSessionPlayerCount and, once the world is loaded, the world
-- GameSession.MaxPlayers, then reads both back; the result names which took.
-- Lasts until the next start; PLAYER_SLOTS in .env makes it permanent.
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

-- In-game administration through the PDA's own Signals > EDIT screen. The
-- hook copies plain values only; all policy and game work waits for the next
-- game-thread poll. Ordinary signal names never enter this queue.
local admin_signal = require('admin_signal')
local ADMIN = admin_signal.new({ admins = os.getenv('SN2_ADMINS') or '',
  prefix = os.getenv('SN2_ADMIN_PREFIX') or '!' })
local ADMIN_HOOK = '/Script/UWEPingSystem.UWEPingSystemCommandComponent:ServerSetPingDisplayName'
local COLOR_HOOK = '/Script/UWEPingSystem.UWEPingSystemCommandComponent:ServerSetThumbnailColor'
local admin_queue, admin_hooked, color_hooked = {}, false, false
-- The answer stays on the signal this long, then its own name and colour come back.
local REPLY_SECONDS = 8
local admin_restores = {} -- guid key -> { ping, name, color, at }
local admin_colors = {}   -- guid key -> { color, at }: the colour picked in the same EDIT

-- Plain copies: a hook's parameters live only for the call, and the work happens
-- on a later tick. Structs are handed back to UFunctions as plain tables.
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

local function admin_receipt(sender, command, r)
  local f, err = io.open(cpath('receipts.jsonl'), 'ab')
  if not f then log('admin receipt not written: ' .. tostring(err)); return end
  local request_id = string.format('%08x%08x%08x%08x', os.time() % 0x100000000,
    math.random(0, 0x7fffffff), math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
  f:write(json.encode({ schema_version = 1, request_id = request_id,
    actor = sender.eos or sender.name, source = 'in_game', command = 'admin.signal',
    arguments = { command = command }, started_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    completed_at = os.date('!%Y-%m-%dT%H:%M:%SZ'), duration_ms = 0,
    exit_code = r.ok and 0 or 77, ok = r.ok, state = r.ok and 'submitted' or 'refused',
    code = r.ok and 'ok' or 'refused', protocol_result = {}, message = r.text }) .. '\n')
  f:close()
end

local function admin_settings(key, value)
  local desired = settings.VERIFIED[key] and settings.VERIFIED[key](value)
  if not desired then return false, nil, 'value out of range' end
  if key == 'weather' then
    local ok, why = set_weather(desired)
    return ok, ok and { value = desired } or nil, why
  end
  local pc = controller_named(os.getenv('SN2_HOST_NAME') or 'SN2 Host')
  local line = desired
  if value == 'frozen' then line = 'FreezeTime'
  elseif value == 'normal' then line = 'UnfreezeTime' end
  local ok, _, err = apply_clock(key, value, pc, line, 'in-game admin ' .. key)
  return ok, ok and { value = value } or nil, err
end

local function admin_call(name, args)
  if name == 'ping' then
    local rows = status.players(to_str)
    local host_name = os.getenv('SN2_HOST_NAME') or 'SN2 Host'
    local lines = {}
    for _, row in ipairs(rows) do
      if row.name ~= host_name and (args.all or row.name == args.sender.name) then
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

-- True only while the store still has this signal: a signal removed during the
-- reply window is never written to (a stale id could crash the game natively).
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

-- After REPLY_SECONDS the signal gets back the name it had before the command
-- (read in the hook, before the rename applied) and the colour the admin's own
-- EDIT sent with it. A second command on the same signal keeps the first
-- original. An unknown original name is left as the answer, and said so.
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

local function admin_drain()
  local q; admin_queue, q = {}, admin_queue
  for _, item in ipairs(q) do
    local sender = item.sender
    local r = admin_signal.run(ADMIN, sender, item.text, { now = os.time, call = admin_call })
    if r and r.silent then
      -- A non-admin: no reply, no restore, no receipt; logged once a minute.
      if r.log then
        log(string.format('admin: ignored %s from %s (eos %s): not an admin', item.text,
          tostring(sender.name), tostring(sender.eos)))
      end
    end
    if r and not r.silent then
      log(string.format('admin command: sender=%s eos=%s command=%s result=%s %s',
        tostring(sender.name), tostring(sender.eos), item.text, r.ok and 'done' or 'refused', r.text))
      admin_receipt(sender, item.text, r)
      admin_reply(item.ping_id, r)
      remember_restore(item)
    end
  end
  admin_restore_due()
end

-- RegisterHook itself must run on the game thread on UE4SS 1190. Retry until
-- the function has loaded; never hook HostSessionAsync (see main.lua).
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
            -- An ordinary rename during a reply window: it wins, no restore over it.
            pcall(function() admin_restores[guid_key(PingId:get())] = nil end)
            return
          end
          pcall(function() ping_id = guid_copy(PingId:get()) end)
          if not ping_id then return end
          -- Before the rename applies (this runs first): the name to give back.
          pcall(function() old = find('UWEPingSystemComponent'):GetPingDisplayName({}, PingId:get()):ToString() end)
          if type(old) ~= 'string' or old == '' or old:sub(1, #ADMIN.prefix) == ADMIN.prefix then old = nil end
          local sender = admin_identity(Context:get())
          admin_queue[#admin_queue + 1] = { sender = sender, ping_id = ping_id, text = text, old_name = old }
        end)
        admin_hooked = true
        log('admin signal hook registered on game thread')
      end
    end
    if not color_hooked then
      local fn = StaticFindObject(COLOR_HOOK)
      if fn and fn:IsValid() then
        -- The PDA's EDIT sends the colour right after the name, under a millisecond
        -- apart: that colour is the one to give back.
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

-- Empty-server policy (idle.lua): FreezeTime after IDLE_FREEZE_MINUTES with no
-- joiner, UnfreezeTime on the next join, and (optional) a stop request after
-- IDLE_STOP_HOURS that the join watcher carries out outside the game.
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
    -- The operator's daylight line: `frozen` holds the clock for everyone until
    -- `normal`; the idle freeze only ever acts on a clock it may touch.
    idle.hold(IDLE, state.daylight_frozen)
    state.daylight_frozen = nil
  end
  for _, act in ipairs(idle.tick(IDLE, joiners, os.time())) do
    local host = controller_named(st.host_name)
    if act == 'freeze' and host then
      log('idle: nobody in for the freeze time; FreezeTime as the host')
      apply_clock('daylight', 'frozen', host, 'FreezeTime', st.host_name .. ' (idle freeze)')
    elseif act == 'unfreeze' and host then
      log('idle: a player joined; UnfreezeTime as the host')
      apply_clock('daylight', 'normal', host, 'UnfreezeTime', st.host_name .. ' (idle unfreeze)')
    elseif act == 'stop' then
      log('idle: nobody in for IDLE_STOP_HOURS; asking the container to stop the game')
      write_atomic(cpath('idle-stop-request.json'), { ts = os.time(), reason = 'idle_stop_hours' })
    end
  end
end

-- The replay ledger survives a game restart. It is deliberately bounded: the
-- newest 1024 nonces cover more than the 120-second acceptance window even at
-- the queue's maximum useful rate.
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
  -- /a:-d: not a directory. Wine's cmd honours no "l" (reparse point) filter:
  -- the -d-l form matched nothing, so every request was refused as non_regular_file
  -- and it follows a symlink as a plain file. Only the container's
  -- own user can write the inbox, so a link there crosses no privilege boundary.
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
          -- The handler runs on the game thread: a UFunction called from this loop fails.
          -- The answer is written when it returns; until then the nonce is in flight,
          -- and a repeat in the same pass is dropped.
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
  -- Answers are useful only briefly: moonpool normally consumes its own. Keep a
  -- hard ceiling for clients that died before reading them.
  local answers = {}
  local p = io.popen('cmd /c dir /b "' .. cpath('outbox') .. '\\*.json" 2>nul')
  if p then for line in p:lines() do answers[#answers + 1] = line:gsub('%s+$', '') end; p:close() end
  table.sort(answers)
  while #answers > 128 do os.remove(cpath('outbox', table.remove(answers, 1))) end
end

-- Crash recovery: mod temporary files were never published, while inbox
-- files were. Remove the former and arrange to answer the latter on the first
-- poll even when the dead process removed .pending before it crashed.
os.execute('cmd /c del /q "' .. cpath('tmp', 'mod-*.json') .. '" 2>nul')
if #list_inbox() > 0 then
  local f = io.open(cpath('inbox', '.pending'), 'wb'); if f then f:close() end
end

-- Launch-cinematic join hold (cinematic_hold.lua says why this way): the game
-- log is tailed from its end; while Gamestate.LifepodAscending is set the
-- session limit is the players already in, so the game refuses a joiner as
-- full; when the tag clears the configured limit is written back and read.
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
-- The log tail and the join replay are two jobs: the replay runs whether or not the
-- log can be opened, and each failure is logged once per distinct reason.
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
    if player then log('player ' .. player .. ' eos=' .. id) end -- the value ADMINS takes
    if LIFEPOD_JOIN_HOLD then hold_act(hold.line(HOLD, l, os.time())) end
    if UNLOCK_REPLAY_ENABLED then pcall(unlock_line, l) end
  end
  if LIFEPOD_JOIN_HOLD then hold_act(hold.tick(HOLD, os.time())) end
end
-- One poll on the game thread: the log tail, then the join replay. An error in
-- either is logged once per message, never swallowed, and one does not stop the other.
local function said_once(what, err)
  local key = what .. '\0' .. tostring(err)
  if not poll_said[key] then poll_said[key] = true; log(what .. ' error: ' .. tostring(err)) end
end
local no_controller_said = {}
local roster_said = nil
local banned_seen = {}
local function hosted_replay()
  local ok, err = pcall(function()
    access.tick(banned_seen, access.names(read_file(cpath('bans.txt'))), cached_players(), HOST_NAME,
      function(name)
        local ran, _, why = handlers.player({ player = HOST_NAME, command = 'KickPlayer ' .. name })
        return ran, why
      end, log)
    local named = player_names()
    -- The roster as this poll sees it, logged whenever it changes (a join, a
    -- leave, a body arriving): name, controller found, body seen.
    local parts = {}
    for _, p in ipairs(cached_players()) do
      local pc = p.name ~= '?' and controller_named(p.name) or nil
      parts[#parts + 1] = string.format('%s (controller %s, body %s)', tostring(p.name),
        pc and 'yes' or 'no', pc and (UNLOCK_GAME.has_body(p.name) and 'yes' or 'no') or '-')
    end
    table.sort(parts) -- FindAllOf order is not stable; an unchanged roster must not re-log
    local roster = #parts == 0 and 'no player states' or table.concat(parts, '; ')
    if roster ~= roster_said then roster_said = roster; log('replay poll sees: ' .. roster) end
    -- A listed player the replay cannot reach is said once, by name or '?',
    -- so a silent joiner is a line in this log, not a guess.
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

-- Main loop: queue and a small readiness file for moonpool status.
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
          local notice_players, names = notify.targets(status.live_players(to_str),
            os.getenv('SN2_HOST_NAME') or 'SN2 Host', notice.players)
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
        -- Build the join replay's lookups once the world is hosted, before anyone
        -- joins, so the first join pays nothing and the log shows what it cost.
        if UNLOCK_REPLAY_ENABLED and not state.asset_index_primed then
          state.asset_index_primed = true
          asset_index()
        end
        local started = os.clock()
        hosted_poll()
        local now = os.time()
        if not state.hosted_cost_logged_at or now - state.hosted_cost_logged_at >= 60 then
          state.hosted_cost_logged_at = now
          log(string.format('hosted poll cost: %.3f ms', (os.clock() - started) * 1000))
        end
      end)
    end
    write_atomic(cpath('readiness.json'), { ts = os.time(), hosted = _G.SN2_HOSTED == true,
      armed = read_file(cpath('HOST_ARMED')) ~= nil })
    process_inbox()
  end)
  if not ok then log('loop error: ' .. tostring(err)) end
  return false
end)

-- status.json: its own 30 s timer, cached lookups only (see status.lua). The
-- Discord script, the viewer status line and the map card read this file.
local STATUS_MS = tonumber(os.getenv('SN2_STATUS_MS') or '') or 30000
-- The world clock as hours (0-24) off the day-sequence actor's GetTimeOfDay, nil when none; the
-- readback a time-of-day setting is verified against. Exact-class order: the game's own actors first
-- (SunMoonDaySequenceActor, UWESkyActor: loaded-class walk), then the subsystem's. Each
-- source names its unit (UWESkyActor answers a day fraction: 0.36 morning, 0.52 after SetTimeOfDay
-- 12:00; the engine's actors answer hours); the unit is never guessed.
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
  -- No clock under those names: say once which loaded actor classes look like
  -- one (names only, nothing called), so the next name to try is in the log.
  if not clock_said and _G.SN2_HOSTED then
    clock_said = true
    -- Every loaded object's class, not only actors: on the headless host the
    -- loaded actors held no clock, so it is a subsystem, a
    -- component or a game-state field.
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

-- The current weather's asset name off the weather sync component (its
-- GetCurrentWeather; a names-only walk of UWEWeatherSyncComponent listed it on
-- and the names of the loaded weather types, which are the
-- values SetCurrentWeather takes. The readback for a weather setting.
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
  -- Said once: the asset path behind each type name, for a command that may
  -- want the path rather than the name (names only, nothing called).
  if #types > 0 and not weather_paths_said then
    weather_paths_said = true
    local parts = {}
    for _, n in ipairs(types) do parts[#parts + 1] = n .. '=' .. tostring(paths[n]) end
    log('weather types: ' .. table.concat(parts, '; '))
  end
  return current, types
end
_G.SN2_WEATHER = weather -- read by tests/lua/host_behaviour_spec.lua

-- The weather setting: the named type handed to the sync component's own
-- SetCurrentWeather (the console forms moved nothing). Called on the game
-- thread already (the armed apply runs in the status loop's game-thread
-- step, the moonpool one in a handler), so it answers at once: true, or false
-- and why, which the card shows as refused. The readback above judges it on
-- the next status write.
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

-- The per-key settings block for status.json and the settings answer: the
-- clock and weather readbacks given, the clock hold's own state as daylight,
-- judged against the latest submission (settings.lua observe). The status
-- write passes its time and marks `verified_at`; the answer passes none and
-- marks nothing. Nothing is applied again here.
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

-- Private voice-range signals. UWEPingSystemComponent is the game's own saved
-- signal store; default visibility is disabled before the one listener is
-- enabled. AddPing and visibility names and arguments come from UWEPingSystem.hpp:111-124.
local VOICE_WARN = (os.getenv('SN2_VOICE_WARN') or 'true') ~= 'false'
local VOICE = voice_range.new({
  range_m = tonumber(os.getenv('SN2_VOICE_RANGE_M') or '') or voice_range.DEFAULT_RANGE_M,
  host = os.getenv('SN2_HOST_NAME') or 'SN2 Host',
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
    -- UWEPingSystem.hpp:111,115: hidden by default, visible only to listener.
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
        host_name = os.getenv('SN2_HOST_NAME') or 'SN2 Host',
        time_of_day = tod, day_fraction = frac,
        weather = wx, weather_types = wxt,
      }, to_str)
      idle_tick(st)
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
