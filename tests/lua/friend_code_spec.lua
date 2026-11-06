-- Fake game for mod/SN2SlotFreeHost/Scripts/friend_code.lua. Plain Lua 5.4:
--   lua5.4 tests/lua/friend_code_spec.lua   (from the repository root)
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local fc = require('friend_code')

local failures = 0
local function eq(got, want, what)
  if got ~= want then
    failures = failures + 1
    print(string.format('not ok %s: got [%s] want [%s]', what, tostring(got), tostring(want)))
  else
    print('ok ' .. what)
  end
end

-- opts.vm: the view model the game made (nil = its Friends screen was never
-- opened); opts.others: players in besides the host; opts.extra: property
-- names beyond the three named ones.
local function game(opts)
  local g = { calls = {}, vm = opts.vm, n = opts.others or 0, finds = 0 }
  g.find_vm = function() g.finds = g.finds + 1; return g.vm end
  g.others = function() return g.n end
  g.call = function(vm, f) g.calls[#g.calls + 1] = f; vm.requested = true; return true end
  g.read = function(vm, p) if vm.requested and vm.after and vm.after <= 0 then return vm[p] end
    if vm.after then vm.after = vm.after - 1 end end
  g.props = function() return opts.extra or {} end
  return g
end

-- A quiet host whose open Friends screen answers on the third tick.
local g = game({ vm = { FriendCode = 'AB12-CD34', after = 2 } })
local job, why = fc.start(g)
eq(why, nil, 'a quiet host gives no refusal reason')
eq(job ~= nil, true, 'a quiet host starts the request')
eq(g.calls[1], 'RequestFriendCode', 'RequestFriendCode is the call made')
eq(job.vm, nil, 'the job holds no view model between ticks')
local code = fc.poll(g, job)
local prop
eq(code, nil, 'tick 1 waits')
fc.poll(g, job)
code, prop = fc.poll(g, job)
eq(code, 'AB12-CD34', 'the code is read back')
eq(prop, 'FriendCode', 'from the FriendCode property')
eq(g.finds, 4, 'the view model is found again on every tick')

-- Another named property answers too.
g = game({ vm = { SonarFriendCode = 'ZZ99', after = 0 } })
job = fc.start(g)
eq(fc.poll(g, job), 'ZZ99', 'read through its other property name')

-- A property under a name we did not guess is found by the code's shape.
g = game({ vm = { CachedCode = '3647-1991', Title = 'Friends', after = 0 }, extra = { 'Title', 'CachedCode' } })
job = fc.start(g)
code, prop = fc.poll(g, job)
eq(code, '3647-1991', 'a code-shaped value under another name is the code')
eq(prop, 'CachedCode', 'and the property is named')
g = game({ vm = { Title = 'Friends', Id = 'abc', after = 0 }, extra = { 'Title', 'Id' } })
job = fc.start(g)
eq(fc.poll(g, job), nil, 'other strings under other names are not taken')

-- Never a constructed view model: no open screen is said plainly.
g = game({})
job, why = fc.start(g)
eq(job, nil, 'no open Friends screen: nothing is requested')
eq(why, 'no_view_model', 'and the reason says so')
eq(#g.calls, 0, 'and nothing was called')

-- The screen closing mid-request ends the poll instead of reading a freed object.
g = game({ vm = { after = 5 } })
job = fc.start(g)
g.vm = nil
local _, gone = fc.poll(g, job)
eq(gone, 'view_model_gone', 'a closed screen ends the poll')

-- Refusals count players other than the host.
g = game({ vm = { after = 0 }, others = 0 })
eq(fc.start(g) ~= nil, true, 'the host alone is a quiet host')
g = game({ vm = { after = 0 }, others = 2 })
job, why = fc.start(g)
eq(job, nil, 'refused while players are online')
eq(why, 'players_online', 'with the reason')
eq(#g.calls, 0, 'and nothing was called')
job = fc.start(g, true)
eq(job ~= nil, true, '--force overrides the refusal')

-- An answer that never comes times out instead of polling forever.
g = game({ vm = { after = 1000 } })
job = fc.start(g)
local last
for _ = 1, fc.MAX_TICKS do code, last = fc.poll(g, job) end
eq(code, nil, 'no code after MAX_TICKS')
eq(last, 'timeout', 'reported as timeout')

-- Junk in the property is not taken for a code.
g = game({ vm = { FriendCode = '', MyFriendCode = 'has space', after = 0 } })
job = fc.start(g)
eq(fc.poll(g, job), nil, 'empty or spaced values are not a code')

eq(fc.is_code('3647-1991'), true, 'the shape takes two groups of four')
eq(fc.is_code('3647-19911'), false, 'and nothing longer')

if failures > 0 then print(failures .. ' failed'); os.exit(1) end
print('all passed')
