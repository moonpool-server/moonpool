-- Fake tag timeline for mod/SN2SlotFreeHost/Scripts/cinematic_hold.lua, built
-- from a host log (join, possession, launch, then tag clearing). Plain Lua 5.4:
--   lua5.4 tests/lua/cinematic_hold_spec.lua   (from the repository root)
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local hold = require('cinematic_hold')

local failures, ran = 0, 0
local function eq(got, want, what)
  ran = ran + 1
  if got ~= want then
    failures = failures + 1
    print(string.format('not ok %s: got [%s] want [%s]', what, tostring(got), tostring(want)))
  else
    print('ok ' .. what)
  end
end
local function kinds(acts)
  local t = {}
  for _, a in ipairs(acts) do t[#t + 1] = a[1] end
  return table.concat(t, ',')
end

-- Seconds after the log's base time.
local s = hold.new()
eq(kinds(hold.line(s, '[2026.10.31-03.00.35:000][  0]LogNet: Join succeeded: Example Diver', 35)), '',
  'a join before the launch is not held')
eq(kinds(hold.line(s, 'LogUWE: Adding global tag Gamestate.LifepodAscending', 52)), 'close',
  'Launch adds the tag: close')
eq(s.held, true, 'held while the tag is set')
eq(kinds(hold.line(s, 'LogUWE: Adding global tag Gamestate.LifepodAscending', 53)), '',
  'a second add while held does nothing')
eq(kinds(hold.line(s, 'LogBink: Loading Bink URL ...', 53)), '', 'other lines do nothing')
eq(kinds(hold.tick(s, 100)), '', 'the clock inside the cinematic does nothing')
local acts = hold.line(s, 'LogUWE: Removing global tag Gamestate.LifepodAscending', 110)
eq(kinds(acts), 'open', 'the tag clears at 03:01:50: open')
eq(acts[1][2]:find('cleared', 1, true) ~= nil, true, 'the open names the tag and why')
eq(s.held, false, 'not held after the clear')
eq(kinds(hold.line(s, 'LogUWE: Removing global tag Gamestate.LifepodAscending', 111)), '',
  'a clear when not held does nothing')

-- A lost "Removing" line: released after MAX_HOLD_S, never stuck closed.
s = hold.new({ max_hold_s = 180 })
hold.line(s, 'Adding global tag Gamestate.LifepodAscending', 1000)
eq(kinds(hold.tick(s, 1179)), '', 'not released at 179 s')
eq(kinds(hold.tick(s, 1180)), 'open', 'released at 180 s')
eq(kinds(hold.tick(s, 1300)), '', 'released once')

-- A different tag is not the cinematic.
s = hold.new()
eq(kinds(hold.line(s, 'Adding global tag Gamestate.LifepodLanded', 5)), '', 'another tag is ignored')

-- The held limit keeps everyone in and lets nobody new in.
eq(hold.hold_limit(3), 3, 'host + 2 joiners: limit 3')
eq(hold.hold_limit(0), 1, 'never below 1')
eq(hold.hold_limit(nil), 1, 'unknown count: 1')

-- Log tailing keeps a partial line for the next read and strips CR.
local lines, rest = hold.split_new('', 'a\r\nb\nAdding global ')
eq(#lines, 2, 'two whole lines')
eq(lines[1], 'a', 'CR stripped')
lines, rest = hold.split_new(rest, 'tag Gamestate.LifepodAscending\n')
eq(lines[1], hold.ADD, 'a line split across reads is joined')
eq(rest, '', 'nothing left over')

print(string.format('%d tests, %d failures', ran, failures))
os.exit(failures == 0 and 0 or 1)
