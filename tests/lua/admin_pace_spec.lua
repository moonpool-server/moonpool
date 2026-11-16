-- Stub-clock tests for mod/SN2SlotFreeHost/Scripts/admin_pace.lua. Plain Lua 5.4:
--   lua5.4 tests/lua/admin_pace_spec.lua   (from the repository root)
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local pace = require('admin_pace')

local failures = 0
local function check(cond, what)
  if cond then print('ok ' .. what) else failures = failures + 1; print('not ok ' .. what) end
end

local q = pace.new(10)
check(pace.take(q, 0) == nil, 'an empty queue gives nothing')
check(pace.push(q, 'a1', 'ada') and pace.push(q, 'a2', 'ada') and pace.push(q, 'b1', 'bo'), 'items queue')
check(pace.take(q, 100) == 'a1', 'the first runs at once'); pace.mark(q, 100)
check(pace.take(q, 105) == nil, 'the next waits for the gap')
check(pace.take(q, 110) == 'a2', 'and runs when the gap is over, in order'); pace.mark(q, 110)
check(pace.take(q, 119) == nil and pace.take(q, 120) == 'b1', 'each later one waits a full gap')
-- An item that ran nothing (not marked) does not start a gap.
local n = pace.new(10)
pace.push(n, 'ignored', 'stranger'); pace.push(n, 'real', 'admin')
check(pace.take(n, 200) == 'ignored' and pace.take(n, 200) == 'real',
  'an item that ran nothing does not hold the next back')
check(pace.size(q) == 0, 'the queue is empty again')

-- One sender cannot hold more than MAX_PER_SENDER places; others still get in.
local s = pace.new(0)
for i = 1, pace.MAX_PER_SENDER do pace.push(s, 'x' .. i, 'spam') end
local ok, why = pace.push(s, 'x-extra', 'spam')
check(not ok and why == 'sender_busy', 'a sender past its share is refused')
check(pace.push(s, 'admin', 'admin'), 'another sender still gets in')

-- The whole queue is bounded.
local f = pace.new(0)
for i = 1, pace.MAX_QUEUED do pace.push(f, i, 'k' .. i) end
ok, why = pace.push(f, 'one too many', 'late')
check(not ok and why == 'queue_full', 'a full queue refuses')

-- A gap of 0 runs one per call, never two at once.
local z = pace.new(0)
pace.push(z, 1, 'a'); pace.push(z, 2, 'b')
check(pace.take(z, 5) == 1 and pace.take(z, 5) == 2, 'gap 0: one per take')

if failures > 0 then os.exit(1) end
local wide = pace.new(1, 12)
for i = 1, 12 do assert(pace.push(wide, i, 'a'), 'a queue with its own cap takes up to it') end
local took, said = pace.push(wide, 13, 'a')
assert(not took and said == 'sender_busy', 'and refuses the next')
-- One Enter can send a line twice; the second copy within the window is a repeat.
local g = pace.new(1)
assert(not pace.repeated(g, 'a', 'Item DA_Glass_ItemType 10', 100), 'a first line is not a repeat')
assert(pace.repeated(g, 'a', 'Item DA_Glass_ItemType 10', 101), 'the same line a second later is')
assert(not pace.repeated(g, 'a', 'Item DA_Glass_ItemType 10', 104), 'the same line after the window is not')
assert(not pace.repeated(g, 'b', 'Item DA_Glass_ItemType 10', 104), 'another sender is not')
assert(not pace.repeated(g, 'a', 'HealMe', 104), 'another line is not')
print('admin_pace: ok')
