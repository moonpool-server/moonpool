-- Stub-clock tests for mod/SN2SlotFreeHost/Scripts/idle.lua (the empty-server
-- policy) and its slots range check. Plain Lua 5.4, no framework: run as
--   lua5.4 tests/lua/idle_spec.lua   (from the repository root)
-- Exits 1 on the first failure; bats runs it in tests/control-protocol.bats.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local idle = require('idle')

local failures, ran = 0, 0
local function eq(got, want, what)
  ran = ran + 1
  local g = table.concat(got, ',')
  if g ~= want then
    failures = failures + 1
    print(string.format('not ok %s: got [%s] want [%s]', what, g, want))
  else
    print('ok ' .. what)
  end
end

-- Freeze after 10 minutes empty, not before; once only.
local s = idle.new({ freeze_s = idle.seconds('10', 60) })
local t = 1000
eq(idle.tick(s, 0, t), '', 'empty at start does nothing')
eq(idle.tick(s, 0, t + 599), '', 'empty 9m59s: still running clock')
eq(idle.tick(s, 0, t + 600), 'freeze', 'empty 10m: freeze')
eq(idle.tick(s, 0, t + 900), '', 'already frozen: no second freeze')

-- The next join unfreezes, once; leaving again restarts the timer.
eq(idle.tick(s, 1, t + 901), 'unfreeze', 'a join unfreezes')
eq(idle.tick(s, 2, t + 950), '', 'more players: nothing')
eq(idle.tick(s, 0, t + 1000), '', 'empty again: timer restarts')
eq(idle.tick(s, 0, t + 1599), '', 'not yet 10m since empty again')
eq(idle.tick(s, 0, t + 1600), 'freeze', 'freeze 10m after the last leave')

-- A player who comes and goes inside the window resets the timer.
s = idle.new({ freeze_s = 600 })
idle.tick(s, 0, 0)
idle.tick(s, 1, 500)
eq(idle.tick(s, 0, 700), '', 'a short visit resets the empty timer')
eq(idle.tick(s, 0, 1300), 'freeze', 'freeze 10m after the short visit')

-- Stop after IDLE_STOP_HOURS; freeze comes first; join clears both.
s = idle.new({ freeze_s = 600, stop_s = idle.seconds('2', 3600) })
idle.tick(s, 0, 0)
eq(idle.tick(s, 0, 600), 'freeze', 'freeze before the stop')
eq(idle.tick(s, 0, 7199), '', 'not yet 2h')
eq(idle.tick(s, 0, 7200), 'stop', 'stop at 2h empty')
eq(idle.tick(s, 0, 9000), '', 'stop asked only once')
eq(idle.tick(s, 1, 9001), 'unfreeze', 'a join after the stop unfreezes')

-- Both at the same tick come out in order.
s = idle.new({ freeze_s = 60, stop_s = 60 })
idle.tick(s, 0, 0)
eq(idle.tick(s, 0, 60), 'freeze,stop', 'freeze then stop on the same tick')

-- Off: empty, 0 and garbage disable a timer.
eq({ tostring(idle.seconds('', 60)) }, 'nil', 'empty setting is off')
eq({ tostring(idle.seconds('0', 60)) }, 'nil', '0 is off')
eq({ tostring(idle.seconds('ten', 60)) }, 'nil', 'garbage is off')
s = idle.new({})
idle.tick(s, 0, 0)
eq(idle.tick(s, 0, 10 ^ 7), '', 'both off: nothing ever')

-- The operator's `daylight: frozen` (held): a join never unfreezes it and the empty
-- timer never freezes it again; `normal` hands the clock back to the idle policy.
s = idle.new({ freeze_s = 600 })
idle.hold(s, true)
eq(idle.tick(s, 1, 0), '', 'held: a player in does not unfreeze')
eq(idle.tick(s, 0, 10), '', 'held: empty again, nothing')
eq(idle.tick(s, 0, 2000), '', 'held: long empty, no second freeze')
idle.hold(s, false)
eq(idle.tick(s, 0, 2001), '', 'normal after a long empty hold: the empty timer restarts, no freeze yet')
eq(idle.tick(s, 0, 2601), 'freeze', 'and freezes freeze_s later as usual')
eq(idle.tick(s, 2, 2602), 'unfreeze', 'a join unfreezes an idle freeze as before')

-- Slots: real slots 1..63 map to a session limit one higher (the host counts).
eq({ tostring(idle.session_limit(8)) }, '9', '8 slots host at 9')
eq({ tostring(idle.session_limit(1)) }, '2', '1 slot hosts at 2')
eq({ tostring(idle.session_limit(63)) }, '64', '63 slots host at 64')
eq({ tostring(idle.session_limit(0)) }, 'nil', '0 slots refused')
eq({ tostring(idle.session_limit(64)) }, 'nil', '64 slots refused')
eq({ tostring(idle.session_limit(4.5)) }, 'nil', 'a fraction refused')
eq({ tostring(idle.session_limit('8')) }, 'nil', 'a string refused')

print(string.format('%d tests, %d failures', ran, failures))
os.exit(failures == 0 and 0 or 1)
