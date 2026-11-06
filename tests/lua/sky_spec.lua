-- Pure-Lua coverage for HH:MM conversion and direct UWESkyActor calls.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local sky = require('sky')
assert(sky.fraction('00:00') == 0)
assert(sky.fraction('12:00') == 0.5)
assert(math.abs(sky.fraction('23:59') - 1439 / 1440) < 0.000001)
assert(sky.fraction('24:00') == nil and sky.fraction('noon') == nil)
local calls = {}
local actor
-- UE4SS refuses a UFunction call with the wrong number of arguments, so the fake does too:
-- SetTimeOfDay(float InHours, const UObject* InCaller), Play(), Pause().
actor = {
  SetTimeOfDay = function(...)
    assert(select('#', ...) == 3, 'SetTimeOfDay takes the time and its caller')
    local _, v, caller = ...
    calls[#calls + 1] = { 'time', v, caller }
    return true
  end,
  Pause = function(...) assert(select('#', ...) == 1); calls[#calls + 1] = { 'pause' } end,
  Play = function(...) assert(select('#', ...) == 1); calls[#calls + 1] = { 'play' } end,
}
assert(sky.apply(actor, 'time_of_day', '06:00'))
assert(sky.apply(actor, 'daylight', 'frozen'))
assert(sky.apply(actor, 'daylight', 'normal'))
assert(calls[1][1] == 'time' and calls[1][2] == 0.25 and calls[1][3] == actor)
assert(calls[2][1] == 'pause' and calls[3][1] == 'play')
local declined = { SetTimeOfDay = function() return false end }
local ok_d, err_d = sky.apply(declined, 'time_of_day', '06:00')
assert(not ok_d and err_d == 'SetTimeOfDay declined')
local ok, err = sky.apply(nil, 'daylight', 'frozen')
assert(not ok and err == 'UWESkyActor not found')
print('all passed')
