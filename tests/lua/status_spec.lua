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
if failures > 0 then os.exit(1) end
print('status_spec: ok')
