-- Shared unlocks on a pruned host.
--
-- A scan unlocks the base
-- piece's story goal on the HOST ("LogScanner: <part> has completed scan",
-- then "LogStoryGoals: Unlocked story goal DA_BasePiece_<X>..."), but with the
-- host's PlayerState pruned from PlayerArray the clients' Habitat Builder never
-- gets the recipe. Goal-level unlocks did not fill the builder. Proven live
-- The command class's `Unlock <name>`, run through
-- KismetSystemLibrary:ExecuteConsoleCommand as the PLAYER's controller, with
-- the name forms below (from the game's own asset index), made the Battery
-- Terminal appear in a client's builder. The game never acknowledges which
-- form took, so every form is sent.
--
-- Four sets (the fourth, the habitat builder bundle, is described at M.BUNDLE);
-- three proven behaviors:
--   * the starter set: the host's DA_BasicBasebuilding_StoryGoal is granted to
--     the host player only, so its pieces go to every player on every join,
--     whether or not the goal shows;
--   * base pieces: each host-side DA_BasePiece_<X> unlock (FORMS below);
--   * scanned tools: each host-side DA_Tools_<X>_StoryGoal unlock (beacon,
--     flare, flashlight, air bladder, wakemaker, sonic resonator, deployable
--     locker, fins / improved fins).
-- One player's lines go to the game as ONE batch, game.send(player, lines):
-- one file of 176 Unlock calls takes about 4 s where one call per file took 30 s each.
--
-- Pure logic: the game is reached only through the callbacks the caller
-- passes, so tests/lua/unlock_replay_spec.lua drives it on a fake game.
local M = {}

-- Proven forms per piece, sent every time.
M.FORMS = {
  BatteryTerminal = { 'DA_BasicBatteryTerminal_ItemType', 'BasicBatteryTerminal',
    'DA_BasicBatteryTerminalConstructData', 'BasicBatteryTerminal_ItemType',
    'DA_BasePiece_BatteryTerminal_ScanData' },
  BioBed = { 'DA_BioBed_ItemType', 'BioBed', 'DA_BioBedConstructData', 'DA_BioBedRecipe',
    'DA_BasePiece_BioBed_ScanData' },
  Biolab = { 'DA_Biolab_ItemType', 'Biolab', 'DA_BioLabConstructData', 'DA_BiolabRecipe',
    'DA_BioLab_Fragment_ScanData', 'DA_WallBiolab_ItemType', 'DA_WallBioLabConstructData',
    'DA_WallBiolabRecipe' },
  CeilingLightSmall = { 'DA_CeilingLight_Rect_A_ItemType', 'CeilingLight_Rect_A',
    'DA_CeilingLight_Rect_A_ConstructData', 'DA_CeilingLight_Rect_A_Recipe',
    'DA_BasePiece_CeilingLightSmall_ScanData' },
  Corridor = { 'DA_BasePiece_Corridor_ScanData', 'Corridor' },
  Hatch = { 'DA_HatchRecipe', 'Hatch', 'DA_BasePiece_Hatch_ScanData' },
  MoonPool = { 'DA_BasePiece_MoonPool_ScanData', 'MoonPool' },
  Processor = { 'DA_Processor_ConstructData', 'DA_ProcessorRecipe', 'Processor',
    'DA_BasePiece_Processor_ScanData' },
  ScannerStation = { 'DA_ScannerStation_ShortRange_ItemType', 'DA_ScannerStation_LongRange_ItemType',
    'DA_ScannerStation_LongRange_ConstructData', 'DA_ScannerStation_LongRange_Recipe',
    'DA_BasePiece_ScannerStationSR_ScanData', 'DA_BasePiece_ScannerStationLR_ScanData',
    'ScannerStation' },
  Spotlight = { 'DA_Spotlight_ItemType', 'Spotlight', 'DA_SpotlightRecipe',
    'DA_BasePiece_Spotlight_ScanData' },
  Window = { 'DA_BasePiece_Window_ScanData', 'Window' },
  SolarPanel = { 'DA_SolarPanel_ItemType', 'DA_SolarPanelRecipe', 'DA_SolarPanelConstructData',
    'DA_BasePiece_SolarPanel_ScanData', 'SolarPanel' },
}

-- The starter set (DA_BasicBasebuilding_StoryGoal), sent to every player on
-- every join. Corridor, Window and Hatch reuse their base-piece forms; Room,
-- Foundation, Ladder, PowerStorage and Glass send the bare name and the scan
-- data, plus every DA_ form a names-only lookup finds.
M.STARTER = { 'SolarPanel', 'Room', 'Corridor', 'Window', 'Foundation', 'Ladder', 'Hatch',
  'PowerStorage', 'Glass' }

-- Variant names, sent only when an object of that exact name exists.
M.EXTRA = {
  SolarPanel = { 'DA_SolarPanelV2_ItemType', 'DA_SolarPanelV2Recipe', 'DA_SolarPanelV2ConstructData',
    'DA_SolarPanel_V2_ItemType', 'DA_SolarPanel_V2_Recipe', 'DA_SolarPanel_V2_ConstructData',
    'DA_SolarPanelMedium_ItemType', 'DA_SolarPanelMediumRecipe', 'DA_SolarPanelMediumConstructData',
    'DA_SolarPanel_Medium_ItemType', 'DA_SolarPanel_Medium_Recipe',
    'DA_SolarPanel_Medium_ConstructData' },
}

-- The habitat builder bundle. Unlocking the Habitat Builder blueprint grants
-- these at once (wiki.subnautica.com/sn2); on a pruned host the grant never
-- reaches a client, so the bundle goes to every player once the host has
-- unlocked BUNDLE_GOAL, on that unlock and on every join. Sent by hand on the
-- with 0 errors. Every name below was
-- checked against the game's asset index (Subnautica2-Windows.utoc) on
-- replayed, including the goal DA_Tools_HabitatBuilder_StoryGoal and the
-- builder tool's own DA_Builder_ItemType / DA_BuilderToolRecipe.
M.BUNDLE_GOAL = 'Tools_HabitatBuilder'
M.BUNDLE = {
  { 'HabitatBuilder', { 'DA_Builder_ItemType', 'DA_BuilderToolRecipe' } },
  { 'Fabricator', { 'DA_Fabricator_ItemType', 'DA_FabricatorRecipe', 'DA_FabricatorConstructData',
    'DA_BasePiece_Fabricator_ScanData' } },
  { 'FabricatorPillar', { 'DA_FabricatorPillar_ItemType', 'DA_FabricatorPillarRecipe',
    'DA_FabricatorPillarConstructData' } },
  { 'Hatch', M.FORMS.Hatch },
  { 'SolarPanel', M.FORMS.SolarPanel },
  { 'Corridor', M.FORMS.Corridor },
  { 'Window', M.FORMS.Window },
  { 'WallLocker', { 'DA_WallLocker_ItemType', 'DA_WallLockerRecipe', 'DA_WallLockerConstructData',
    'DA_BasePiece_WallLocker_ScanData' } },
  { 'PortableLocker', { 'DA_FloatingLocker_Carryable_ItemType', 'DA_FloatingLockerCarryable_Recipe',
    'DA_FloatingLockerCarryable_ConstructData' } },
  { 'NoATerminal', { 'DA_BasePiece_NoATerminal_ScanData' } },
  { 'CeilingLightSmall', M.FORMS.CeilingLightSmall },
  { 'HabitatBeacon', { 'DA_BaseSignal_ItemType', 'DA_BaseSignal_Recipe', 'DA_BaseSignalConstructData' } },
  { 'Radio', { 'DA_Radio_ItemType', 'DA_RadioRecipe', 'DA_RadioConstructData' } },
}

-- Every form in the bundle, in order, each once.
function M.bundle_forms()
  local out, seen = {}, {}
  for _, entry in ipairs(M.BUNDLE) do
    for _, n in ipairs(entry[2]) do
      if not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
  end
  return out
end

-- Candidates sent only when a names-only lookup finds an asset of that name
-- (the "plus any ... by name" forms of the receipt, and the variants above).
function M.candidates(piece)
  local out = { 'DA_' .. piece .. '_ItemType', 'DA_' .. piece .. 'ConstructData',
    'DA_' .. piece .. '_ConstructData', 'DA_' .. piece .. 'Recipe', 'DA_' .. piece .. '_Recipe' }
  for _, n in ipairs(M.EXTRA[piece] or {}) do out[#out + 1] = n end
  return out
end

-- A tool's key in the set and in status.json is Tools_<X>, as in its goal name.
local TOOL = '^Tools_(.+)$'
function M.set_of(key)
  if key == M.BUNDLE_GOAL then return 'bundle' end
  return key:match(TOOL) and 'tools' or 'pieces'
end

-- What the log calls a key.
function M.label(key)
  if key == M.BUNDLE_GOAL then return 'habitat builder bundle' end
  return key
end

-- The key a goal or scan-data name belongs to, or nil for anything else:
-- DA_BasePiece_<X>... gives <X> (ScannerStationSR/LR mean ScannerStation),
-- DA_Tools_<X>_StoryGoal gives Tools_<X>.
function M.piece_of(goal)
  if type(goal) ~= 'string' then return nil end
  local short = goal:match('([%w_]+)$') or goal
  short = short:match('^.-%.(.+)$') or short -- /Game/...DA_X.DA_X -> DA_X
  local tool = short:match('^DA_Tools_([%w_]+)$')
  if tool then
    tool = tool:gsub('_StoryGoal$', ''):gsub('_ScanData$', '')
    if tool == '' then return nil end
    return 'Tools_' .. tool
  end
  local rest = short:match('^DA_BasePiece_([%w_]+)$')
  if not rest then return nil end
  rest = rest:gsub('_StoryGoal$', ''):gsub('_ScanData$', ''):gsub('_Fragment$', '')
  if rest:match('^ScannerStation[SL]R$') then rest = 'ScannerStation' end
  if rest == '' then return nil end
  return rest
end

-- Every form to send for a key, no duplicates, in order. A tool sends
-- DA_<X>_ItemType, DA_<X>Recipe and DA_<X>_ScanData always, then
-- DA_<X>_Recipe, DA_Tools_<X>_ScanData and the bare name when they exist by
-- name. A base or starter piece sends its proven list (or the bare name and
-- scan data), then the candidates the lookup finds.
function M.forms(key, exists)
  local out, seen = {}, {}
  local function add(n) if not seen[n] then seen[n] = true; out[#out + 1] = n end end
  local function found(n)
    if not exists then return false end
    local ok, f = pcall(exists, n)
    return ok and f == true
  end
  if key == M.BUNDLE_GOAL then
    for _, n in ipairs(M.bundle_forms()) do add(n) end
    return out
  end
  local tool = key:match(TOOL)
  if tool then
    add('DA_' .. tool .. '_ItemType')
    add('DA_' .. tool .. 'Recipe')
    add('DA_' .. tool .. '_ScanData')
    for _, n in ipairs({ 'DA_' .. tool .. '_Recipe', 'DA_Tools_' .. tool .. '_ScanData', tool }) do
      if found(n) then add(n) end
    end
    return out
  end
  local proven = M.FORMS[key]
  if proven then
    for _, n in ipairs(proven) do add(n) end
  else
    add(key)
    add('DA_BasePiece_' .. key .. '_ScanData')
  end
  for _, n in ipairs(M.candidates(key)) do
    if found(n) then add(n) end
  end
  return out
end

-- State: the keys unlocked on the host for one save, in unlock order, and the
-- players already replayed to this session.
function M.new(save, pieces, scans)
  local st = { save = save, pieces = {}, have = {}, known = {}, scans = {}, scanned = {} }
  for _, p in ipairs(pieces or {}) do
    if not st.have[p] then st.have[p] = true; st.pieces[#st.pieces + 1] = p end
  end
  for _, s in ipairs(scans or {}) do
    if type(s) == 'string' and not st.scanned[s] then st.scanned[s] = true; st.scans[#st.scans + 1] = s end
  end
  return st
end

-- Seed from the previous status.json only when it was written for the same
-- save; another save's recipes are never granted.
function M.seed(save, prev)
  if type(prev) == 'table' and type(prev.unlocks) == 'table' and prev.unlocks.save == save then
    return M.new(save, prev.unlocks.pieces, prev.unlocks.scans)
  end
  return M.new(save)
end

-- One host log line. Returns the key when it is a NEW base-piece or tool unlock.
function M.line(st, l)
  local goal = l:match('LogStoryGoals: Unlocked story goal%s+([%w_/%.]+)')
  local piece = M.piece_of(goal)
  if not piece or st.have[piece] then return nil end
  st.have[piece] = true
  st.pieces[#st.pieces + 1] = piece
  return piece
end

-- The Unlock lines for a list of keys, each form once across the list.
-- Returns the lines and, per key, how many new lines it added.
function M.lines(keys, exists)
  local out, seen, per = {}, {}, {}
  for i, key in ipairs(keys) do
    per[i] = 0
    for _, form in ipairs(M.forms(key, exists)) do
      if not seen[form] then
        seen[form] = true
        out[#out + 1] = 'Unlock ' .. form
        per[i] = per[i] + 1
      end
    end
  end
  return out, per
end

-- One batch to one player; an empty batch is not sent.
-- PACING. A burst of Unlock lines through one controller froze that client's
-- toolbar on its current slot until a relog (80 to 326
-- lines, 20 ms apart). Lines go out M.interval_ms apart (UNLOCK_INTERVAL_MS,
-- default 50, clamped 10..2000); game.send receives the interval and spaces them.
M.DEFAULT_INTERVAL_MS = 50
function M.interval_ms(v)
  local n = tonumber(v)
  if not n or n ~= n then return M.DEFAULT_INTERVAL_MS end
  n = math.floor(n)
  if n < 10 then return 10 elseif n > 2000 then return 2000 end
  return n
end
M.interval = M.DEFAULT_INTERVAL_MS

-- When each line of a batch goes out, in ms after the batch starts.
function M.schedule(lines, interval)
  local out = {}
  for i, line in ipairs(lines) do out[i] = { at = (i - 1) * interval, line = line } end
  return out
end

-- After a batch, one toolbar re-sync line if the game has one. The command
-- class's names (services_functions.txt) hold Equip, EquipAll,
-- Equipment, ExpandInventory and ExpandToolbar: each changes what the player
-- carries or the toolbar's size, none only re-syncs it, so none is sent. Left
-- empty on purpose.
M.TOOLBAR_RESYNC = nil

local function send(game, player, lines)
  if #lines > 0 then
    if M.TOOLBAR_RESYNC then lines[#lines + 1] = M.TOOLBAR_RESYNC end
    game.send(player, lines, M.interval)
  end
  return #lines
end

-- Everything to one player in ONE batch: the starter set, then every base
-- piece and tool the host has unlocked. One log line with the counts.
function M.replay(st, game, player)
  local keys, sets = {}, {}
  for _, k in ipairs(M.STARTER) do keys[#keys + 1] = k; sets[#keys] = 'starter' end
  for _, k in ipairs(st.pieces) do keys[#keys + 1] = k; sets[#keys] = M.set_of(k) end
  local lines, per = M.lines(keys, game.exists)
  local count = { starter = 0, pieces = 0, tools = 0, bundle = 0 }
  for i, n in ipairs(per) do count[sets[i]] = count[sets[i]] + n end
  local scan = M.scan_replay_lines(st, game, lines)
  for _, l in ipairs(scan) do lines[#lines + 1] = l end
  local n = send(game, player, lines)
  st.known[player] = true
  game.log(string.format(
    'unlocks replayed to %s: %d (starter %d, habitat builder bundle %d, base pieces %d, tools %d, scans %d)',
    player, n, count.starter, count.bundle, count.pieces, count.tools, #scan))
  return n
end

-- A new host-side unlock: its forms to every connected non-host player, one
-- batch each.
function M.broadcast(game, piece, names, host)
  local sent = {}
  local lines = M.lines({ piece }, game.exists)
  for _, name in ipairs(names) do
    if name ~= host then
      local n = send(game, name, lines)
      game.log(string.format('unlock %s sent to %s: %d forms', M.label(piece), name, n))
      sent[#sent + 1] = name
    end
  end
  return sent
end

-- WHEN. The batch should land while the joiner is still loading or in the
-- lifepod cinematic, before input is enabled. The mod reaches no PostLogin or
-- possession hook by name (main.lua hooks only Actor:ReceiveBeginPlay and
-- HostSessionAsync), and "input enabled" is not a property it can read, so it
-- uses the fallback: the first poll that sees the joiner's body (game.has_body)
-- starts a clock, and the batch goes out M.DELAY_MS later, once the HUD is up.
-- Whether that is before the player has control is unproven until a real
-- joiner on the clean re-proof host.
M.DELAY_MS = 2000

-- One batch per joiner per mod session: a rejoin does not replay again (a
-- second burst is what froze the toolbar); moonpool unlocks replay still does.
-- game.now() is the clock in ms; without game.has_body every name has a body.
function M.joins(st, game, names, host)
  local joined = {}
  st.body_at = st.body_at or {}
  local now = game.now and game.now() or 0
  local delay = game.now and M.DELAY_MS or 0
  st.seen = st.seen or {}
  for _, name in ipairs(names) do
    if name ~= host and not st.known[name] then
      local body = (game.has_body == nil) or game.has_body(name)
      -- Said once per name, so the log shows which hop a silent joiner stops at.
      if not st.seen[name] and game.log then
        st.seen[name] = true
        game.log('unlocks: ' .. name .. ' has a controller; body ' .. (body and 'yes' or 'not yet'))
      end
      if not body then
        st.body_at[name] = nil
      elseif not st.body_at[name] then
        st.body_at[name] = now
        if game.log and delay > 0 then game.log('unlocks: ' .. name .. ' has a body; batch in ' .. delay .. ' ms') end
      end
      if body and now - st.body_at[name] >= delay then
        M.replay(st, game, name)
        st.body_at[name] = nil
        joined[#joined + 1] = name
      end
    end
  end
  return joined
end

-- SCANS. The host logs every finished scan as
--   LogScanner: <display name> has completed scan
-- and for furniture, posters, lights and tools that scan grants the recipe
-- straight to the scanning player, with no story goal; on a pruned host the
-- grant never reaches a client. Replayed by hand
-- (x7: 22 scans, 163 names, 326 calls, 0 errors). No scanner
-- completion function is reachable by name from the host mod, so the log line
-- is the trigger (the same tail the story-goal unlocks use).
--
-- The display name maps to its *_ScanData asset(s) through each loaded scan
-- data object's Name text (game.scan_assets, built in main.lua by one
-- read-only ForEachUObject pass). From each asset name the forms are derived:
-- the ScanData itself, then for every base spelling (with and without the
-- BasePiece_/Tools_/Poster_/Salvage_ prefix, a trailing _A or _01 dropped,
-- underscores removed, and every two-part word split in both orders, as in
-- DiningChair_ScanData vs ChairDining_Recipe) the siblings _ItemType, Recipe
-- and ConstructData that exist by name, and an UnlockStoryGoal for an
-- existing <base>_StoryGoal. A scan with no ItemType/Recipe/ConstructData
-- sibling (creatures, flora, raw resources) sends nothing.
M.SCAN_LINE = 'LogScanner: (.-) has completed scan'
M.SCAN_PREFIXES = { 'BasePiece_', 'Tools_', 'Poster_', 'Salvage_' }
-- Bases whose item name the asset name does not spell; each pair read off
-- recorded per-scan name sets.
M.SCAN_ALIAS = {
  BatteryTerminal = { 'BasicBatteryTerminal' },
  CeilingLightSmall = { 'CeilingLight_Rect_A' },
  ScannerStationLR = { 'ScannerStation_LongRange' },
  ScannerStationSR = { 'ScannerStation_ShortRange' },
  DeployableLocker = { 'FloatingLockerCarryable', 'FloatingLocker_Carryable', 'FloatingLocker' },
  HabitatBuilder = { 'Builder', 'BuilderTool' },
  Interior_LightWall = { 'Light_Wall_Small' },
}
local SIBLINGS = { '_ItemType', 'ItemType', '_Recipe', 'Recipe', '_ConstructData', 'ConstructData' }

-- The display name of a finished scan, or nil.
function M.scan_of(l)
  if type(l) ~= 'string' then return nil end
  local name = l:match(M.SCAN_LINE)
  if not name then return nil end
  name = name:gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then return nil end
  return name
end

-- Every base spelling worth looking up for one *_ScanData asset name.
function M.scan_bases(asset)
  local short = asset:match('([%w_]+)$') or asset
  local b = short:match('^DA_(.+)_ScanData$')
  if not b then return {} end
  b = b:gsub('_Fragment$', '')
  local out, seen = {}, {}
  local function add(x) if x ~= '' and not seen[x] then seen[x] = true; out[#out + 1] = x end end
  local roots = { b }
  for _, p in ipairs(M.SCAN_PREFIXES) do
    if b:sub(1, #p) == p then roots[#roots + 1] = b:sub(#p + 1) end
  end
  for i = 1, #roots do
    local trimmed = roots[i]:gsub('_%w%w?$', '') -- Shelf_S_A -> Shelf_S, X_01 -> X
    if trimmed ~= roots[i] then roots[#roots + 1] = trimmed end
    local nosize = roots[i]:gsub('[LS]R$', '') -- ScannerStationLR -> ScannerStation
    if nosize ~= roots[i] then roots[#roots + 1] = nosize end
  end
  for _, r in ipairs(roots) do
    for _, a in ipairs(M.SCAN_ALIAS[r] or {}) do add(a) end
    add(r)
    local flat = r:gsub('_', '')
    add(flat)
    -- The variants the game names beside the item: an upgraded V2, a carried
    -- copy, a wall-mounted one (Beacon/BeaconCarryable, Biolab/WallBiolab).
    add(flat .. 'V2'); add(flat .. 'Carryable'); add('Wall' .. flat)
    local words = {}
    for w in flat:gmatch('%u[%l%d]*') do words[#words + 1] = w end
    if table.concat(words) == flat then
      for i = 1, #words - 1 do
        local x = table.concat(words, '', 1, i)
        local y = table.concat(words, '', i + 1)
        add(x .. '_' .. y); add(y .. x); add(y .. '_' .. x)
      end
    end
  end
  return out
end

-- The console lines for one ScanData asset: nothing unless an item sibling
-- exists. exists(name) returns the game's own spelling (or true).
function M.scan_lines(asset, exists)
  local function found(n)
    if not exists then return nil end
    local ok, f = pcall(exists, n)
    if not ok or not f then return nil end
    return type(f) == 'string' and f or n
  end
  local out, seen, items = {}, {}, 0
  local function add(l) if not seen[l] then seen[l] = true; out[#out + 1] = l end end
  add('Unlock ' .. asset)
  local bases = M.scan_bases(asset)
  for _, b in ipairs(bases) do
    for _, s in ipairs(SIBLINGS) do
      local n = found('DA_' .. b .. s)
      if n and not seen['Unlock ' .. n] then add('Unlock ' .. n); items = items + 1 end
    end
  end
  if items == 0 then return {} end
  for _, b in ipairs(bases) do
    for _, p in ipairs({ '', 'BasePiece_', 'Tools_' }) do
      local g = found('DA_' .. p .. b .. '_StoryGoal')
      if g then add('UnlockStoryGoal ' .. g) end
    end
  end
  return out
end

-- Every line for one display name, across all its ScanData assets, cached in
-- the state (the lookups run once per display name per session).
function M.scan_forms(st, game, display)
  st.scan_cache = st.scan_cache or {}
  if st.scan_cache[display] then return st.scan_cache[display] end
  local assets = {}
  if game.scan_assets then
    local ok, a = pcall(game.scan_assets, display)
    if ok and type(a) == 'table' then assets = a end
  end
  local out, seen = {}, {}
  for _, asset in ipairs(assets) do
    for _, l in ipairs(M.scan_lines(asset, game.exists)) do
      if not seen[l] then seen[l] = true; out[#out + 1] = l end
    end
  end
  -- An unknown name is not cached, so a later index rebuild can find it.
  if #assets > 0 then st.scan_cache[display] = out end
  return out
end

-- One host log line. Returns the display name when it is a NEW finished scan.
function M.scan(st, l)
  local name = M.scan_of(l)
  st.scans = st.scans or {}
  st.scanned = st.scanned or {}
  if not name or st.scanned[name] then return nil end
  st.scanned[name] = true
  st.scans[#st.scans + 1] = name
  return name
end

-- A new finished scan: its lines to every connected non-host player, one
-- batch each. A scan that sends nothing is logged once, so a wrong display
-- name or a missing index shows.
function M.scan_broadcast(st, game, display, names, host)
  local lines = M.scan_forms(st, game, display)
  if #lines == 0 then
    game.log(string.format('scan %s: no recipe to share', display))
    return {}
  end
  local sent = {}
  for _, name in ipairs(names) do
    if name ~= host then
      local n = send(game, name, lines)
      game.log(string.format('scan %s sent to %s: %d lines', display, name, n))
      sent[#sent + 1] = name
    end
  end
  return sent
end

-- The scan lines a joiner needs, each line once, not repeating `already`.
function M.scan_replay_lines(st, game, already)
  local out, seen = {}, {}
  for _, l in ipairs(already or {}) do seen[l] = true end
  for _, d in ipairs(st.scans or {}) do
    for _, l in ipairs(M.scan_forms(st, game, d)) do
      if not seen[l] then seen[l] = true; out[#out + 1] = l end
    end
  end
  return out
end

-- What status.json keeps.
function M.snapshot(st)
  return { save = st.save, pieces = st.pieces, scans = st.scans or {} }
end

return M
