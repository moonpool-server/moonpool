package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local notify = require('notify')
local failures = 0
local function eq(a,b,n) if a~=b then failures=failures+1; print('not ok '..n) else print('ok '..n) end end
local logs, static_calls, client_calls = {}, 0, 0
local players = {{ NotificationComponent = { ClientNotify=function() client_calls=client_calls+1 end } }}
local g = { world=function() return 'world' end, log=function(x) logs[#logs+1]=x end,
  find=function() return { SendNotificationToPlayers=function(_, _, d, p)
    static_calls=static_calls+1; eq(d.Type,6,'warning type'); eq(d.HeaderText,'Soon','header'); eq(#p,1,'players')
  end } end }
eq(notify.send(g,players,'warning','Soon','Saved',8),true,'static succeeds')
eq(static_calls,1,'static used'); eq(client_calls,0,'no fallback')
g.find=function() return { SendNotificationToPlayers=function() error('no') end } end
eq(notify.send(g,players,'info','Hello','World',5),true,'fallback succeeds'); eq(client_calls,1,'fallback used')
notify.send(g,players,'info','Again','World',5); eq(#logs,3,'failures and successes logged once')
eq(notify.data('info','H','T',3).Type,5,'info type')
local live = {{name='SN2 Host',player='h'},{name='Diver',player='d'},{name='Pilot',player='p'}}
local ps, ns = notify.targets(live, 'SN2 Host')
eq(#ps,2,'everyone but the host'); eq(ns[1],'Diver','first name')
ps, ns = notify.targets(live, 'SN2 Host', {'Pilot'})
eq(#ps,1,'only the listed joiner'); eq(ps[1],'p','the joiner object'); eq(ns[1],'Pilot','the joiner name')
ps = notify.targets(live, 'SN2 Host', {'SN2 Host'})
eq(#ps,0,'the host is never a target')
if failures>0 then os.exit(1) end
print('all passed')
