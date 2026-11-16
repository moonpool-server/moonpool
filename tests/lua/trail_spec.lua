-- Tests for mod/SN2SlotFreeHost/Scripts/trail.lua.
--   lua5.4 tests/lua/trail_spec.lua   (from the repository root)
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local trail = require('trail')

local failures = 0
local function check(cond, what)
  if cond then print('ok ' .. what) else failures = failures + 1; print('not ok ' .. what) end
end

local t = trail.new()
trail.add(t, { { name = 'Host', x = 900000, y = 900000 }, { name = 'Ada', x = 12000, y = -100 } }, 'Host')
trail.add(t, { { name = 'Ada', x = 12500, y = -50 } }, 'Host') -- the same square again
trail.add(t, { { name = 'Ada', x = 17000, y = -50 } }, 'Host')
local got = trail.take(t)
check(table.concat(got, ' ') == '2,-1 3,-1', 'each square once, the host never: ' .. table.concat(got, ' '))
check(#trail.take(t) == 0, 'a take empties the batch')

trail.add(t, { { name = 'Ada', x = 0, y = 0 }, { name = 'Bo', x = 150, y = -150 } }, 'Host')
check(#trail.take(t) == 0, 'a player without a body, at the origin, adds nothing')

trail.add(t, { { name = 'Ada', x = 'x', y = 5 }, { name = 'Bo' } }, 'Host')
check(#trail.take(t) == 0, 'a row without a position adds nothing')

local rows = {}
for i = 1, trail.MAX + 50 do rows[#rows + 1] = { name = 'Ada', x = i * 5000 + 1000, y = 1000 } end
trail.add(t, rows, 'Host')
check(#trail.take(t) == trail.MAX, 'a batch never holds more than MAX squares')

if failures > 0 then os.exit(1) end
print('trail: ok')
