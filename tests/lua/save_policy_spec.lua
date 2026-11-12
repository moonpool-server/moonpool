-- Stub-clock tests for mod/SN2SlotFreeHost/Scripts/save_policy.lua. Plain Lua 5.4:
--   lua5.4 tests/lua/save_policy_spec.lua   (from the repository root)
-- Counts every failure and exits 1 at the end if any; bats runs it in tests/control-protocol.bats.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local sp = require('save_policy')

local failures = 0
local function eq(got, want, what)
  local g = table.concat(got, ',')
  if g ~= want then
    failures = failures + 1
    print(string.format('not ok %s: got [%s] want [%s]', what, g, want))
  else
    print('ok ' .. what)
  end
end

-- Off: nothing is ever sent, the game's autosave is left alone.
local off = sp.new({ every_s = nil })
eq(sp.tick(off, 0, true, { 'A' }, 3), '', 'off: an autosave changes nothing')
eq(sp.tick(off, 9999, true, {}, 0), '', 'off: no schedule, no leave save')

-- Not hosted yet: nothing, even with autosave lines from the lobby.
local s = sp.new({ every_s = 600 })
eq(sp.tick(s, 100, false, {}, 1), '', 'lobby: nothing before the world is up')

-- First tick up: no autosave seen yet, so no toggle; no save yet.
eq(sp.tick(s, 1000, true, { 'A', 'B' }, 0), '', 'up, no autosave seen: no blind toggle')
-- The game's own autosave arrives: autosave is on, so it is switched off, once.
eq(sp.tick(s, 1030, true, { 'A', 'B' }, 1), 'autosave_off', 'game autosave seen: switch it off')
eq(sp.tick(s, 1060, true, { 'A', 'B' }, 0), '', 'quiet after the toggle')
-- Another game autosave too soon after the toggle is not answered with a second toggle.
eq(sp.tick(s, 1100, true, { 'A', 'B' }, 1), '', 'within RETOGGLE_S: no second toggle')
-- One later still means the toggle did not take: it is sent again.
eq(sp.tick(s, 1250, true, { 'A', 'B' }, 1), 'autosave_off', 'autosave still on after RETOGGLE_S: toggle again')

-- A player leaves: one save for the batch, even when two leave in one tick.
eq(sp.tick(s, 1280, true, {}, 0), 'save', 'two leave in one tick: one save')
-- The save logs autosave_completed; that line is the host's own, not the game's.
eq(sp.tick(s, 1290, true, {}, 1), '', "own save's line is not a game autosave")
-- A join is not a save.
eq(sp.tick(s, 1320, true, { 'C' }, 0), '', 'a join does not save')

-- The schedule: every_s after the last save, whatever caused it.
eq(sp.tick(s, 1879, true, { 'C' }, 0), '', 'before every_s: no save')
eq(sp.tick(s, 1880, true, { 'C' }, 0), 'save', 'every_s after the leave save: scheduled save')
eq(sp.tick(s, 2000, true, { 'C' }, 0), '', 'the schedule restarted')

-- Back to the lobby (a restart): forget who was in, so the first tick up is not a leave.
eq(sp.tick(s, 2100, false, {}, 0), '', 'lobby again')
eq(sp.tick(s, 2130, true, {}, 0), '', 'up again with nobody: not a leave')

if failures > 0 then os.exit(1) end
print('save_policy: ok')
