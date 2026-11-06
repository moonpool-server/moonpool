-- This fake counts the game-object scan boundary without loading UE4SS.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local poll = require('hosted_poll')
local failures, scans, holds, replays, now = 0, 0, 0, 0, 0
local live = { ['/Game/PS1'] = true }
local function check(value, message)
  if value then print('ok ' .. message) else failures = failures + 1; print('FAIL ' .. message) end
end
local state = poll.new({
  safety_s = 60, now = function() return now end,
  find = function(path) return live[path] and { path = path } or nil end,
  valid = function(o) return o ~= nil end,
  hold = function() holds = holds + 1 end,
  refresh = function() scans = scans + 1; return { '/Game/PS1' } end,
  replay = function() replays = replays + 1 end,
})

poll.tick(state)
scans, holds, replays = 0, 0, 0
poll.tick(state)
check(scans == 0, 'a steady two-second poll performs no scan')
check(holds == 1 and replays == 0, 'steady polling still advances the lifepod hold only')
poll.mark_dirty(state)
poll.tick(state)
check(scans == 1, 'a join signal refreshes the roster once')
check(holds == 2 and replays == 1, 'a join runs the lifepod hold and replay')
scans = 0; now = 59; poll.tick(state)
check(scans == 0, 'the safety scan waits for sixty seconds')
now = 60; poll.tick(state)
check(scans == 1, 'the sixty-second safety interval refreshes once')

print(string.format('%d failures', failures))
os.exit(failures == 0 and 0 or 1)
