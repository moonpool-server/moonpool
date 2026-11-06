-- Pure-Lua checks for name-based access enforcement.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local access = require('access')
local fails = 0
local function check(v, why) print((v and 'ok ' or 'not ok ') .. why); if not v then fails = fails + 1 end end

local bans = access.names('# operator policy\nAlice\treason stays private\n76561198000000022\tID only\nBOB\n')
check(bans.alice and bans.bob and not bans['76561198000000022'], 'only name entries become in-game bans')

local seen, kicked, logs = {}, {}, {}
local function tick(roster)
  access.tick(seen, bans, roster, 'SN2 Host', function(n) kicked[#kicked + 1] = n end,
    function(s) logs[#logs + 1] = s end)
end
tick({{name='SN2 Host'}, {name='Alice'}, {name='Carol'}})
tick({{name='Alice'}})
check(#kicked == 1 and kicked[1] == 'Alice', 'a banned name is kicked once while present')
check(#logs == 1 and logs[1]:find('Alice', 1, true), 'the removal is logged without its reason')
tick({})
tick({{name='ALICE'}})
check(#kicked == 2 and kicked[2] == 'ALICE', 'a rejoin is kicked again, case-insensitively')

-- A kick that could not run (no host controller) is never logged as done: it is
-- logged once and retried until it runs.
local s2, tries, l2, works = {}, 0, {}, false
local function tick2(roster)
  access.tick(s2, bans, roster, 'SN2 Host', function()
    tries = tries + 1
    if works then return true end
    return false, 'unknown_player'
  end, function(s) l2[#l2 + 1] = s end)
end
tick2({{name='Bob'}}); tick2({{name='Bob'}})
check(tries == 2, 'a failed kick is retried on the next tick')
check(#l2 == 1 and l2[1]:find('could not remove banned player Bob: unknown_player', 1, true),
  'a failed kick is logged once, with the reason, not as removed')
works = true
tick2({{name='Bob'}}); tick2({{name='Bob'}})
check(tries == 3 and l2[2]:find('removed banned player Bob', 1, true), 'once it runs it is done and logged')

print(fails == 0 and 'all passed' or (fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
