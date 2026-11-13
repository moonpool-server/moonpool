-- status.lua keeps player paths, never objects: a freed PlayerState is never read again.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local failures = 0
local function eq(a, b, n)
  if a == b then print('ok ' .. n) return end
  failures = failures + 1
  print('not ok ' .. n .. ' (got ' .. tostring(a) .. ')')
end

local live = {}
local function player(path, name)
  local o = { IsValid = function() return true end,
    GetFullName = function() return 'BP_SN2PlayerState_C ' .. path end,
    PlayerNamePrivate = { ToString = function() return name end } }
  live[path] = o
  return o
end
local diver = player('/Game/L.L:PersistentLevel.PS_1', 'Diver')
player('/Game/L.L:PersistentLevel.PS_2', 'Pilot')
local searches = 0
_G.FindAllOf = function(c)
  if c ~= 'PlayerState' then return nil end
  searches = searches + 1
  local all = {}
  for _, o in pairs(live) do all[#all + 1] = o end
  return all
end
_G.StaticFindObject = function(path) return live[path] end

local status = require('status')
local to_str = function(v) return v end
eq(status.path_of('BP_SN2PlayerState_C /Game/L.L:PersistentLevel.PS_1'), '/Game/L.L:PersistentLevel.PS_1',
  'path_of drops the class')
eq(status.path_of('/Script/Engine.PlayerState'), '/Script/Engine.PlayerState', 'a bare path is kept')
eq(status.path_of(nil), nil, 'no name, no path')
eq(#status.players(to_str, 'L_Main'), 2, 'both players listed')
eq(searches, 1, 'one search')
status.players(to_str, 'L_Main')
eq(searches, 1, 'the next read finds the kept paths again without a search')

-- The engine frees Diver and hands its address to another object: anything that reads the
-- old one now follows garbage. The kept path no longer finds it, so it is never touched.
live['/Game/L.L:PersistentLevel.PS_1'] = nil
setmetatable(diver, { __index = function() error('read a freed PlayerState') end })
diver.PlayerNamePrivate, diver.GetFullName = nil, nil
local ok, list = pcall(status.players, to_str, 'L_Main')
eq(ok, true, 'a freed player is never read')
eq(ok and #list or -1, 1, 'only the live player is listed')
eq(ok and list[1].name or '', 'Pilot', 'the live player is the one left')
status.players(to_str, 'L_Main')
eq(searches, 2, 'a missing path makes the next read search again')

-- A built base is one UWESculpturalBaseActor, and a save restores it before the first search.
local function base(x, cells, placed)
  return { TotalCells = cells, bNetStartup = placed,
    K2_GetActorLocation = function() return { X = x, Y = 0, Z = -100 } end }
end
local saved_find = _G.FindAllOf
_G.FindAllOf = function(c)
  if c == 'UWESculpturalBaseActor' then
    return { base(50000, 12, false), base(90000, 0, false), base(130000, 9, true) }
  end
  return saved_find(c)
end
local built = status.build({ map = 'L_Bases' }, to_str).bases
eq(#built, 1, "only a player's base with cells is listed")
eq(built[1] and built[1].x or 0, 50000, 'at the position of the base actor')
_G.FindAllOf = saved_find

-- The signals everyone sees are listed with their positions; hidden ones and admin commands are not.
local function guid(a) return { A = a, B = 0, C = 0, D = 0 } end
local function arr(items)
  return { ForEach = function(_, f) for i, v in ipairs(items) do f(i, { get = function() return v end }) end end }
end
local function sig(id, name, x, follows)
  return { UniqueID = guid(id), DisplayName = { ToString = function() return name end },
    Location = { X = x, Y = 20.4, Z = -30 }, bHasTrackingActor = follows == true }
end
local store = { DefaultHiddenPings = arr({ guid(2) }),
  ActivePings = arr({ sig(1, 'Base', 10.6), sig(2, 'voice range', 11), sig(3, '!help', 12), sig(4, '', 13),
    sig(5, string.rep('x', 80), 14, true) }) }
local signals = status.signals(store, '!')
eq(#signals, 2, 'the hidden signal, the admin command and the nameless one are left out')
eq(signals[1].name .. '@' .. signals[1].x .. ',' .. signals[1].y .. ',' .. signals[1].z, 'Base@11,20,-30',
  'a signal keeps its name and position')
eq(#signals[2].name, 60, 'a long name is cut to 60 characters')
eq(#status.signals(nil, '!'), 0, 'no signal store, no signals')
eq(tostring(signals[1].tracked) .. ',' .. tostring(signals[2].tracked), 'false,true',
  'a signal that follows something is marked')
local unreadable = { ActivePings = store.ActivePings,
  DefaultHiddenPings = setmetatable({}, { __index = function() error('cannot read') end }) }
eq(#status.signals(unreadable, '!'), 0, 'an unreadable hidden list publishes nothing')

-- A search of every loaded object stalls the game thread, so each is made once and its find kept.
local walks = { all = 0 }
_G.FindAllOf = function(c) walks.all = walks.all + 1; return saved_find(c) end
status.build({ map = 'L_Bases' }, to_str)
local before = walks.all
status.invalidate()  -- as the players request does
status.players(to_str)
eq(walks.all - before, 1, 'a refreshed player list is one search, for the players')
status.build({ map = 'L_Bases' }, to_str)
eq(walks.all - before, 1, 'and, naming no map, does not make the next status search the world again')

local sky_name = 'UWESkyActor /Game/L.L:Sky'
local sky = { IsValid = function() return true end, GetFullName = function() return sky_name end }
local there = true
_G.FindFirstOf = function(c) walks[c] = (walks[c] or 0) + 1; return there and c == 'UWESkyActor' and sky or nil end
eq(status.first('UWESkyActor'), sky, 'first finds the object')
status.first('UWESkyActor')
eq(walks.UWESkyActor, 1, 'and the second time hands back the one it kept, without a search')
sky_name = 'Fish /Game/L.L:Fish'  -- the game gave the address to something else
there = false
eq(status.first('UWESkyActor'), nil, 'an object whose name has changed is not handed back')
eq(walks.UWESkyActor, 1, 'and is not searched for again at once')
eq(status.first('Nothing'), nil, 'a class that is not there finds nothing')
status.first('Nothing')
eq(walks.Nothing, 1, 'and is not searched for again at once')
local clock = os.time
rawset(os, 'time', function() return clock() + 60 end)
status.first('Nothing')
eq(walks.Nothing, 2, 'but is once the wait is over')

_G.FindAllOf = function(c) walks[c] = (walks[c] or 0) + 1; return { sky } end
eq(#status.all('Weather', 600), 1, 'all lists what a search found')
sky_name = 'Fish /Game/L.L:Other'
eq(#status.all('Weather', 600), 0, 'without what has since gone')
eq(walks.Weather, 1, 'and searches once while the list is fresh')
rawset(os, 'time', function() return clock() + 3600 end)
status.all('Weather', 600)
eq(walks.Weather, 2, 'then again once it is old')
rawset(os, 'time', clock)
if failures > 0 then os.exit(1) end
print('status_spec: ok')
