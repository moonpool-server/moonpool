-- Runs SN2SlotFreeHost's main.lua against a fake game and asserts what it DOES:
-- the Host call is made once when armed, the lobby and world limits are written,
-- hosted is claimed only after the session limit reads back, the host's
-- PlayerState is pruned, the lifepod goals unlock once on the first real body,
-- and the recipe's slots handler changes the three limits.
-- Run: lua5.4 tests/lua/host_behaviour_spec.lua
local dir = 'mod/SN2SlotFreeHost/Scripts/'
package.path = dir .. '?.lua;' .. package.path

local fails = 0
local function check(c, msg) if not c then fails = fails + 1; io.stderr:write('FAIL: ' .. msg .. '\n') end end

local function obj(t) t = t or {}; t.IsValid = function() return true end; return t end
local function fstr(v) return { ToString = function() return v end } end
local function class(name) return { GetFName = function() return fstr(name) end } end
local log = {}
local real_print = print
_G.print = function(...) local p = {} for i = 1, select('#', ...) do p[#p + 1] = tostring(select(i, ...)) end
  log[#log + 1] = table.concat(p, ' ') end

-- The fake game.
local calls = { host = 0, goals = 0 }
-- Objects the fake engine can find again by path (status.lua keeps paths, not objects).
local by_path = {}
local function placed(path, t)
  local o = obj(t)
  o.GetFullName = function() return 'PlayerState ' .. path end
  by_path[path] = o
  return o
end
local host_ps = placed('/Game/L_Main.L_Main:PersistentLevel.PS_Host', { PlayerNamePrivate = fstr('SN2 Host') })
local joiner = placed('/Game/L_Main.L_Main:PersistentLevel.PS_Diver',
  { PlayerNamePrivate = fstr('Diver'), PawnPrivate = nil })
local gs = obj({ PlayerArray = { host_ps, joiner } })
local subsystem = obj({ MaxSessionPlayerCount = 4 })
subsystem.HostSessionAsync = function() calls.host = calls.host + 1 end
local lobby_session = obj({ MaxPlayers = 4 })
lobby_session.GetClass = function() return class('BP_SN2GameSession_C') end
local lobby = obj({ GameSession = lobby_session })
local hooks = {}
-- The game's Host spawns a lobby GameSession at its default of 4; the BeginPlay hook raises it.
lobby.HostSession = function() calls.host = calls.host + 1
  local h = hooks['/Script/Engine.Actor:ReceiveBeginPlay']
  if h then h({ get = function() return lobby_session end }) end
end
local world_session = obj({ MaxPlayers = 4 })
local world_gm = nil -- appears after the map loads
local goals = obj({})
local unlocked = {}
goals.UnlockStoryGoal = function(_, g) calls.goals = calls.goals + 1; unlocked[g] = true end
local statics = obj({ IsStoryGoalUnlocked = function(_, _, g) return unlocked[g] == true end })

local found = {
  GameStateBase = function() return gs end,
  UWEOnlineSessionSubsystem = function() return subsystem end,
  PlayerController = function() return obj({}) end,
  BP_ClientLobbyGameMode_C = function() return lobby end,
  BP_SN2WorldGameMode_C = function() return world_gm end,
  GameSession = function() return world_gm and world_session or lobby_session end,
  UWEStoryGoalsWorldSubsystem = function() return goals end,
}
_G.FindFirstOf = function(c) local f = found[c]; return f and f() or nil end
_G.FindAllOf = function() return nil end
-- The engine's ability-system library answers for any actor that has an ASC, as the engine does.
local asc_library = obj({ GetAbilitySystemComponent = function(_, actor)
  return actor and actor.GetASC and actor:GetASC() or nil
end })
_G.StaticFindObject = function(path)
  if by_path[path] then return by_path[path] end
  if path:find('UWEStoryGoalsStatics') then return statics end
  if path:find('AbilitySystemBlueprintLibrary') then return asc_library end
  return obj({})
end
local loops = {}
_G.LoopAsync = function(_, f) loops[#loops + 1] = { f = f } end
_G.ExecuteWithDelay = function(_, f) f() end
_G.ExecuteInGameThread = function(f) f() end
_G.RegisterHook = function(name, f) hooks[name] = f; return 1, 1 end
_G.NotifyOnNewObject = function() end
_G.RegisterConsoleCommandHandler = function() end

local ctl = os.tmpname(); os.remove(ctl); os.execute('mkdir -p "' .. ctl .. '"')
local env = {
  SN2_PLAYER_SLOTS = '8', SN2_HOST_NAME = 'SN2 Host', SN2_CONTROL_WIN = ctl,
  SN2_HOST_PRUNE = 'true', SN2_ARM_SETTLE_SECS = '4',
  -- The direct sky clock is off by default; these checks exercise it.
  SN2_SKY_CLOCK = 'true',
}
local real_getenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] end return real_getenv(k) end
local function tick(n)
  for _ = 1, n or 1 do
    for _, l in ipairs(loops) do if not l.done then l.done = l.f() == true end end
  end
end

local ok, err = pcall(dofile, dir .. 'main.lua')
check(ok, 'main.lua loads: ' .. tostring(err))

do
  local save_calls, forced = 0, nil
  local host = obj({ PlayerState = obj({ PlayerNamePrivate = fstr('SN2 Host') }), SaveCommunication = obj({}) })
  host.SaveCommunication.TriggerAsyncAutoSaveGame = function(_, force)
    save_calls = save_calls + 1; forced = force
  end
  local saved_all = _G.FindAllOf
  _G.FindAllOf = function(c) if c == 'PlayerController' then return { host } end return saved_all(c) end
  local save_ok, save_data, save_err = _G.SN2_HANDLERS.save({})
  check(save_ok == true, 'save handler accepts the host save request: ' .. tostring(save_err))
  check(save_data and save_data.forced == true, 'save receipt says that the save was forced')
  check(save_calls == 1 and forced == true, 'save handler forces one async save on the host controller')
  _G.FindAllOf = saved_all
end

tick(3)
check(calls.host == 0, 'no Host call while HOST_ARMED is absent')
check(_G.SN2_HOSTED ~= true, 'not hosted before arming')

-- The mod joins the control dir and the marker with a Windows backslash.
local marker = ctl .. '\\HOST_ARMED'
local f = io.open(marker, 'w'); f:write('1'); f:close()
os.getenv = function(k)
  if k == 'SN2_CONTROL_WIN' then return ctl end
  if env[k] ~= nil then return env[k] end
  return real_getenv(k)
end
-- Armed before the lobby exists (the service arms before launch): the attempt is held, not spent.
local lobby_fn, pc_fn = found.BP_ClientLobbyGameMode_C, found.PlayerController
found.BP_ClientLobbyGameMode_C = function() return nil end
found.PlayerController = function() return nil end
tick(5)
check(calls.host == 0, 'armed early: no Host call while there is no lobby yet')
found.BP_ClientLobbyGameMode_C, found.PlayerController = lobby_fn, pc_fn
-- Lobby found: the call settles (the network login finishes after the lobby appears).
tick(2)
check(calls.host == 0, 'lobby found: no Host call while settling')
tick(1)
check(calls.host == 1, 'exactly one Host call once armed (got ' .. calls.host .. ')')
tick(20)
check(calls.host == 1, 'the Host call is never repeated')
check(lobby_session.MaxPlayers == 9,
  'lobby limit written to PLAYER_SLOTS+1 (got ' .. tostring(lobby_session.MaxPlayers) .. ')')
check(_G.SN2_HOSTED == true, 'hosted claimed after the session limit read back 9')

-- The map loads: world game mode appears.
world_gm = obj({})
tick(5)
check(world_session.MaxPlayers == 9,
  'world GameSession.MaxPlayers written to 9 (got ' .. tostring(world_session.MaxPlayers) .. ')')
check(#gs.PlayerArray == 1 and gs.PlayerArray[1] == joiner, 'host PlayerState pruned, joiner kept')
check(calls.goals == 0, 'goals not unlocked before a real body')
joiner.PawnPrivate = obj({ HealthSetComponent = obj({ RestoreHealth = function() end }) })
tick(5)
check(calls.goals >= 1, 'lifepod goals unlocked on the first real body')
local after = calls.goals
tick(10)
check(calls.goals == after, 'goals unlocked only once')

-- The recipe's slots handler changes the three limits.
local h = _G.SN2_HANDLERS
check(type(h) == 'table' and type(h.slots) == 'function', 'recipe exposes its handlers')
if h and h.slots then
  -- In the lobby: the subsystem limit and the lobby session's MaxPlayers.
  local okc, okv, res = pcall(h.slots, { slots = 6 })
  check(okc and okv, 'slots handler runs in the lobby')
  check(subsystem.MaxSessionPlayerCount == 7, 'slots 6 writes the subsystem limit 7')
  check(lobby_session.MaxPlayers == 7, 'slots 6 writes the lobby session limit 7')
  check(type(res) == 'table' and res.took and res.took.lobby_subsystem and res.took.lobby_game_session,
    'slots reports both lobby limits read back')
  -- In the world (no lobby game mode): the subsystem limit and the world session's MaxPlayers.
  found.BP_ClientLobbyGameMode_C = function() return nil end
  local okw, okw2, resw = pcall(h.slots, { slots = 10 })
  check(okw and okw2, 'slots handler runs in the world')
  check(subsystem.MaxSessionPlayerCount == 11, 'slots 10 writes the subsystem limit 11')
  check(world_session.MaxPlayers == 11, 'slots 10 writes the world session limit 11')
  check(type(resw) == 'table' and resw.took and resw.took.world_game_session == true,
    'slots reports the world limit read back')
  found.BP_ClientLobbyGameMode_C = function() return lobby end
end
if h and h.receipt then
  local okr, data = h.receipt()
  check(okr and type(data) == 'table' and data.hosted == true, 'receipt returns a structured receipt with hosted=true')
end

-- A player state that answers nothing to GetPlayerName (the live build on
-- is still named from its own PlayerNamePrivate, the way status.lua
-- and main.lua already read it: players are listed by name and a per-player
-- command finds the controller instead of answering unknown_player.
if h and h.players and h.player then
  local joiner_pc = obj({ PlayerState = joiner, Pawn = obj({}) })
  _G.FindAllOf = function(c)
    if c == 'PlayerState' then return { host_ps, joiner } end
    if c == 'PlayerController' then return { joiner_pc } end
    return nil
  end
  local okp, _, listed = pcall(h.players)
  local names = {}
  if okp and type(listed) == 'table' then
    for _, p in ipairs(listed.players or {}) do names[#names + 1] = p.name end
  end
  check(table.concat(names, ',') == 'SN2 Host,Diver',
    'players are named from PlayerNamePrivate when GetPlayerName answers nothing (got '
    .. table.concat(names, ',') .. ')')
  local okc, _, _, perr = pcall(h.player, { player = 'Diver', command = 'Unlock SolarPanel' })
  check(okc and perr ~= 'unknown_player',
    'a per-player command finds the controller by that name (err=' .. tostring(perr) .. ')')
  _G.FindAllOf = function() return nil end
end

-- The world clock readback: GetTimeOfDay off the sky or day-sequence actor,
-- a fraction of the day (UWESkyActor, measured) or hours (the engine actor),
-- given back as HH:MM with the fraction beside; nil when the world has none.
do
  local tod = assert(_G.SN2_TIME_OF_DAY, 'recipe exposes time_of_day')
  check(tod() == nil, 'no clock actor: no time of day')
  local saved = _G.FindFirstOf
  local source, answer = 'UWESkyActor', 0.52
  _G.FindFirstOf = function(c)
    if c == source then return obj({ GetTimeOfDay = function() return answer end }) end
    return saved(c)
  end
  local hhmm, frac = tod()
  check(hhmm == '12:29' and frac == 0.52,
    'the sky actor answers a day fraction (got ' .. tostring(hhmm) .. ' ' .. tostring(frac) .. ')')
  answer = 0.15
  check((tod()) == '03:36', 'the 03:00 probe plus drift reads 03:36')
  source, answer = 'DaySequenceActor', 13.4567
  hhmm, frac = tod()
  check(hhmm == '13:27' and frac == 0.561,
    'the engine actor answers hours (got ' .. tostring(hhmm) .. ' ' .. tostring(frac) .. ')')
  answer = 0.5
  check((tod()) == '00:30',
    'an hours clock before 01:00 is not mistaken for a fraction (got ' .. tostring((tod())) .. ')')
  answer = 0 / 0
  check(tod() == nil, 'a non-finite answer is no clock')
  _G.FindFirstOf = saved
end

-- The weather readback: the current weather's asset name off the sync
-- component, and the loaded weather type names, sorted, the class default
-- left out; nothing when the world has no sync component.
do
  local wx = assert(_G.SN2_WEATHER, 'recipe exposes weather')
  local current, types = wx()
  check(current == nil and #types == 0, 'no sync component: no weather, no types')
  local saved_first, saved_all = _G.FindFirstOf, _G.FindAllOf
  local function asset(name) return obj({ GetFName = function() return fstr(name) end }) end
  _G.FindFirstOf = function(c)
    if c == 'UWEWeatherSyncComponent' then
      return obj({ GetCurrentWeather = function() return asset('DA_Weather_Clear') end })
    end
    return saved_first(c)
  end
  _G.FindAllOf = function(c)
    if c == 'UWEWeatherTypeBase' then
      return { asset('DA_Weather_Storm'), asset('Default__BP_DA_WeatherBase_C'), asset('DA_Weather_Clear'),
        asset('DA_Weather_Storm') }
    end
    return nil
  end
  current, types = wx()
  check(current == 'DA_Weather_Clear', 'the current weather is named (got ' .. tostring(current) .. ')')
  check(table.concat(types, ',') == 'DA_Weather_Clear,DA_Weather_Storm',
    'weather types sorted, once each, no class default (got ' .. table.concat(types, ',') .. ')')
  _G.FindFirstOf, _G.FindAllOf = saved_first, saved_all
  _G.FindAllOf = function() return nil end
end

-- The weather setting: the named loaded type handed to the sync component's
-- own SetCurrentWeather; an unknown name calls nothing.
do
  local set = assert(_G.SN2_SET_WEATHER, 'recipe exposes the weather setter')
  local saved_first, saved_all = _G.FindFirstOf, _G.FindAllOf
  local function asset(name) return obj({ GetFName = function() return fstr(name) end }) end
  local given = {}
  _G.FindFirstOf = function(c)
    if c == 'UWEWeatherSyncComponent' then
      return obj({ SetCurrentWeather = function(_, t) given[#given + 1] = t:GetFName():ToString() end })
    end
    return saved_first(c)
  end
  _G.FindAllOf = function(c)
    if c == 'UWEWeatherTypeBase' then return { asset('DA_Weather_Storm'), asset('DA_Weather_Clear') } end
    return nil
  end
  local set_ok = set('DA_Weather_Clear')
  check(set_ok == true and #given == 1 and given[1] == 'DA_Weather_Clear',
    'the named type is handed to SetCurrentWeather')
  local set_ok2, why = set('DA_Rain')
  check(set_ok2 == false and why == 'no loaded weather type named DA_Rain' and #given == 1,
    'an unknown type name calls nothing and says so (got ' .. tostring(why) .. ')')
  _G.FindFirstOf, _G.FindAllOf = saved_first, saved_all
  _G.FindAllOf = function() return nil end
end

-- moonpool settings: the card's applied rows are the calls that ran. With no
-- sky actor and host controller the clock key is refused by that reason; the
-- weather call needs no controller, only a loaded type of that name.
do
  local yf = assert(io.open(ctl .. '\\settings.yaml', 'w'))
  yf:write('time_of_day: "08:00"\nweather: rain\nmods: []\n'); yf:close()
  local function rows()
    local hok, data = h.settings()
    check(hok == true, 'settings apply answers ok')
    local by = {}
    for _, v in ipairs(data.values) do by[v.key] = v end
    return by
  end
  local by = rows()
  local tod_reason = by.time_of_day and by.time_of_day.reason
  check(by.time_of_day and by.time_of_day.applied == false and tod_reason == 'UWESkyActor not found',
    'a missing sky actor and fallback controller are refused (got ' .. tostring(tod_reason) .. ')')
  local wx_reason = by.weather and by.weather.reason
  check(by.weather and by.weather.applied == false and wx_reason == 'no weather sync component',
    'weather with no sync component is refused by that reason (got ' .. tostring(wx_reason) .. ')')
  local saved_first, saved_all = _G.FindFirstOf, _G.FindAllOf
  local function asset(name) return obj({ GetFName = function() return fstr(name) end }) end
  _G.FindFirstOf = function(c)
    if c == 'UWEWeatherSyncComponent' then return obj({ SetCurrentWeather = function() end }) end
    return saved_first(c)
  end
  _G.FindAllOf = function(c)
    if c == 'UWEWeatherTypeBase' then return { asset('DA_Clear') } end
    if c == 'PlayerState' then return { joiner } end
    return nil
  end
  by = rows()
  check(by.weather.applied == false and by.weather.reason == 'no loaded weather type named DA_Rain',
    'a type the host has not loaded is refused by name (got ' .. tostring(by.weather.reason) .. ')')
  yf = assert(io.open(ctl .. '\\settings.yaml', 'w'))
  yf:write('weather: clear\nmods: []\n'); yf:close()
  by = rows()
  check(by.weather.applied == true and by.weather.value == 'clear', 'a loaded type is applied and shown so')
  _G.FindFirstOf, _G.FindAllOf = saved_first, saved_all
  _G.FindAllOf = function() return nil end
  os.remove(ctl .. '\\settings.yaml')
end

-- The answer and status.json carry the per-key block: what was asked, what
-- ran, the readback, and when it first showed, which is a status write's
-- time even when the answer's own look already saw the value; the weather's
-- own cycle afterwards changes the readback and nothing else, with no second
-- call to the setter.
do
  local json = require('json')
  local function status_file()
    local fh = assert(io.open(ctl .. '\\status.json', 'rb'))
    local raw = fh:read('a'); fh:close()
    return json.decode(raw)
  end
  local yf = assert(io.open(ctl .. '\\settings.yaml', 'w'))
  yf:write('time_of_day: "08:00"\nweather: clear\nmods: []\n'); yf:close()
  local saved_first, saved_all = _G.FindFirstOf, _G.FindAllOf
  local function asset(name) return obj({ GetFName = function() return fstr(name) end }) end
  local current, sets = 'DA_Clear', 0
  _G.FindFirstOf = function(c)
    if c == 'UWEWeatherSyncComponent' then
      return obj({
        SetCurrentWeather = function() sets = sets + 1 end,
        GetCurrentWeather = function() return asset(current) end,
      })
    end
    return saved_first(c)
  end
  _G.FindAllOf = function(c)
    if c == 'UWEWeatherTypeBase' then return { asset('DA_Clear') } end
    if c == 'PlayerState' then return { joiner } end
    return nil
  end
  local hok, a = h.settings()
  check(hok == true and sets == 1, 'the weather call ran once')
  check(#a.requested == 2 and a.requested[2].key == 'weather' and a.requested[2].desired == 'DA_Clear',
    'requested lists every configured key in its compared form')
  check(#a.submitted == 1 and a.submitted[1].key == 'weather' and a.submitted[1].value == 'DA_Clear',
    'submitted lists the call that ran')
  check(#a.refused == 1 and a.refused[1].key == 'time_of_day' and a.refused[1].reason == 'UWESkyActor not found',
    'refused lists the key and why')
  check(a.observed.weather == 'DA_Clear' and a.observed.time_of_day == nil,
    'observed is the readback now, a missing one absent (got ' .. tostring(a.observed.weather) .. ')')
  check(a.settings.weather.submitted == true and a.settings.weather.verified_at == json.null
    and a.settings.weather.observed == 'DA_Clear', 'the answer shows the value and marks nothing')
  check(a.settings.time_of_day.submitted == false and a.settings.time_of_day.observed == json.null
    and a.settings.time_of_day.reason == 'UWESkyActor not found', 'a refused key: not submitted, no readback')
  check(#a.values == 2, 'the older rows still ride along')
  -- The next status write records when the value showed.
  require('status').invalidate()
  tick(1)
  local st = status_file()
  local wx = st.settings and st.settings.weather
  check(wx and wx.observed == 'DA_Clear'
    and type(wx.verified_at) == 'string' and wx.verified_at:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'),
    'status.json records when the value first showed (got ' .. tostring(wx and wx.verified_at) .. ')')
  local first = wx and wx.verified_at
  check(st.settings.daylight == nil, 'a key not configured has no row')
  check(st.settings.time_of_day.submitted == false and st.settings.time_of_day.verified_at == json.null,
    'a refused key stays unverified in status.json')
  -- The weather cycles on its own: the readback moves, verified_at stays,
  -- and the setter is not called again.
  current = 'DA_StormA'
  tick(2)
  wx = status_file().settings.weather
  check(wx.observed == 'DA_StormA' and wx.verified_at == first and wx.drifted == nil,
    'the natural cycle moves the readback only (got ' .. tostring(wx.observed) .. ')')
  check(sets == 1, 'the setter is never called again (calls: ' .. sets .. ')')
  _G.FindFirstOf, _G.FindAllOf = saved_first, saved_all
  _G.FindAllOf = function() return nil end
  os.remove(ctl .. '\\settings.yaml')
  os.remove(ctl .. '\\status.json')
end

-- The join replay's lookups come from one FindAllOf('DataAsset') and are answered
-- from a table, never by walking every object: a ForEachUObject scan index plus a
-- FindObject per candidate name froze the game thread for 47-67 s on one join and
-- preceded a UE4SS crash.
do
  local g = _G.SN2_UNLOCK_GAME
  check(type(g) == 'table' and type(g.exists) == 'function' and type(g.scan_assets) == 'function',
    'recipe exposes the unlock game adapter')
  if g then
    local walks, asked = 0, 0
    local saved_each, saved_find, saved_all = _G.ForEachUObject, _G.FindObject, _G.FindAllOf
    _G.ForEachUObject = function() walks = walks + 1 end
    _G.FindObject = function() walks = walks + 1 end
    local function asset(short, display)
      return obj({ GetFName = function() return fstr(short) end, Name = display and fstr(display) or nil })
    end
    _G.FindAllOf = function(c)
      if c == 'DataAsset' then
        asked = asked + 1
        return { asset('DA_FlashLight_ItemType'), asset('DA_Tools_Scanner_ScanData', 'Scanner'),
                 asset('DA_Scanner_ItemType') }
      end
      return saved_all and saved_all(c) or nil
    end
    _G.SN2_ASSET_INDEX_RESET()
    check(g.exists('DA_Flashlight_ItemType') == 'DA_FlashLight_ItemType',
      "exists answers in the game's own spelling, case-blind")
    check(g.exists('DA_Nothing_ItemType') == false, 'a name nothing carries is false')
    local scans = g.scan_assets('Scanner')
    check(scans[1] == 'DA_Tools_Scanner_ScanData', 'a scan display name maps to its ScanData asset')
    for i = 1, 50 do g.exists('DA_Probe' .. i .. '_Recipe') end
    check(walks == 0, 'no lookup walks every object (got ' .. walks .. ' walks)')
    check(asked == 1, 'one FindAllOf serves every lookup (got ' .. asked .. ')')
    _G.ForEachUObject, _G.FindObject, _G.FindAllOf = saved_each, saved_find, saved_all
  end
end

-- The join replay's lookups come from one FindAllOf('DataAsset') and are answered
-- from a table, never by walking every object: a ForEachUObject scan index plus a
-- FindObject per candidate name froze the game thread for 47-67 s on one join and
-- preceded a UE4SS crash.
do
  local g = _G.SN2_UNLOCK_GAME
  check(type(g) == 'table' and type(g.exists) == 'function' and type(g.scan_assets) == 'function',
    'recipe exposes the unlock game adapter')
  if g then
    local walks, asked = 0, 0
    local saved_each, saved_find, saved_all = _G.ForEachUObject, _G.FindObject, _G.FindAllOf
    _G.ForEachUObject = function() walks = walks + 1 end
    _G.FindObject = function() walks = walks + 1 end
    local function asset(short, display)
      return obj({ GetFName = function() return fstr(short) end, Name = display and fstr(display) or nil })
    end
    _G.FindAllOf = function(c)
      if c == 'DataAsset' then
        asked = asked + 1
        return { asset('DA_FlashLight_ItemType'), asset('DA_Tools_Scanner_ScanData', 'Scanner'),
                 asset('DA_Scanner_ItemType') }
      end
      return saved_all and saved_all(c) or nil
    end
    _G.SN2_ASSET_INDEX_RESET()
    check(g.exists('DA_Flashlight_ItemType') == 'DA_FlashLight_ItemType',
      "exists answers in the game's own spelling, case-blind")
    check(g.exists('DA_Nothing_ItemType') == false, 'a name nothing carries is false')
    local scans = g.scan_assets('Scanner')
    check(scans[1] == 'DA_Tools_Scanner_ScanData', 'a scan display name maps to its ScanData asset')
    for i = 1, 50 do g.exists('DA_Probe' .. i .. '_Recipe') end
    check(walks == 0, 'no lookup walks every object (got ' .. walks .. ' walks)')
    check(asked == 1, 'one FindAllOf serves every lookup (got ' .. asked .. ')')
    _G.ForEachUObject, _G.FindObject, _G.FindAllOf = saved_each, saved_find, saved_all
  end
end

_G.print = real_print
os.remove(marker); os.remove(ctl)
if fails > 0 then for _, l in ipairs(log) do print('  log: ' .. l) end; os.exit(1) end
print('host_behaviour_spec: all checks passed')
