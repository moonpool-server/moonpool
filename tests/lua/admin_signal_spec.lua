-- Pure-Lua coverage for beacon admin parsing, access, mapping and replies.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local admin = require('admin_signal')
local failures = 0
local function eq(got, want, what)
  if got ~= want then
    failures = failures + 1
    print('not ok ' .. what .. ': got [' .. tostring(got) .. '] want [' .. tostring(want) .. ']')
  else print('ok ' .. what) end
end
local now, calls = 100, {}
local function game()
  return { now = function() return now end, call = function(name, args)
    calls[#calls + 1] = { name, args }
    if name == 'slots' then return true, { slots = args.slots } end
    if name == 'time' or name == 'weather' then return true, { value = args.value } end
    if name == 'ping' then
      if args.all then return true, { lines = { 'Alice · 12 ms', 'Bob · 34 ms' } } end
      return true, { lines = { (args.sender.name or '?') .. ' · 34 ms' } }
    end
    return true, {}
  end }
end
local s = admin.new({ admins = 'Alice, 76561198000000000, AAAABBBBCCCCDDDDEEEEFFFF00001111' })
local ALICE = { name = 'Alice', eos = 'aaaabbbbccccddddeeeeffff00001111' }

eq(admin.parse('ordinary', '!'), nil, 'ordinary rename ignored')
eq(admin.parse('!slots 8', '!').command, 'slots', 'prefix parsed')
eq(admin.parse('/help', '/').command, 'help', 'custom prefix parsed')
eq(admin.authorized(s.admins, { name = 'Alice' }), false, 'a name is never an admin, even one listed')
eq(admin.authorized(s.admins, ALICE), true, 'the EOS id is the admin')
eq(admin.authorized(s.admins, { name = 'Mallory', steamid = '76561198000000000', eos = 'ffff' }), false,
  'a claimed Steam ID is not an admin, listed or not')
local ADD = 'LogNet: AddClientConnection: Added client connection: '
  .. '[UNetConnection] RemoteAddr: EOS:%s, Name: %s, Driver: x'
local ids = admin.new({})
admin.note_connection(ids, 'LogNet: something else')
eq(admin.connection_id(ids, 'IpConnection_1'), nil, 'other lines are ignored')
admin.note_connection(ids, ADD:format('AAAA1111', 'IpConnection_1'))
eq(admin.connection_id(ids, 'IpConnection_1'), 'aaaa1111', 'the connection gives the id')
eq(admin.connection_id(ids, 'IpConnection_2'), nil, 'another connection has none')
admin.note_connection(ids, 'LogNet: UNetConnection::Close: [UNetConnection] '
  .. 'RemoteAddr: EOS:AAAA1111, Name: IpConnection_1, x')
eq(admin.connection_id(ids, 'IpConnection_1'), nil, 'a closed connection is forgotten')
local who, id = admin.login_label('LogNet: Login request: ?Name=Bob??PlatformUserId=7656?PlatformProvider=STEAM '
  .. 'userId: EOS:|aaaa1111 platform: EOS')
eq(who, 'Bob', 'the login line labels the id for the operator'); eq(id, 'aaaa1111', 'with the server-side id')
-- A Steam ID entry never matches a player NAMED like it.
eq(admin.authorized(s.admins, { name = '76561198000000000' }), false,
  'a name spelled like an admin Steam ID is not an admin')
eq(admin.authorized(s.admins, { name = '76561198000000000', steamid = '76561198000000001' }), false,
  'nor with a different real Steam ID')

local r = admin.run(s, { name = 'Bob' }, '!ping', game())
eq(r.text, 'Bob · 34 ms', 'non-admin can read own ping')
now = now + 3
r = admin.run(s, ALICE, '!ping', game())
eq(r.text, 'Alice · 12 ms\nBob · 34 ms', 'admin sees every player ping')
calls = {}

r = admin.run(s, { name = 'Bob' }, '!slots 8', game())
eq(r.text, 'admins only', 'non-admin refused')
eq(r.silent, true, 'a non-admin gets no reply on the signal'); eq(r.log, true, 'the first try is logged')
eq(#calls, 0, 'refusal runs nothing')
r = admin.run(s, { name = 'Bob' }, '!slots 8', game())
eq(r.silent, true, 'still silent'); eq(r.log, false, 'repeats within a minute are not logged again')
r = admin.run(s, ALICE, '!slots 8', game())
eq(r.text, 'slots now 8', 'slot reply'); eq(r.color, 'green', 'success is green')
eq(calls[1][1], 'slots', 'slot handler mapped')
r = admin.run(s, ALICE, '!weather clear', game())
eq(r.text, 'please wait a moment', 'same sender rate limited'); eq(#calls, 1, 'rate limit runs nothing')
now = now + 3
r = admin.run(s, ALICE, '!time 08:00', game())
eq(r.text, 'time 08:00', 'time reply')
eq(calls[2][1], 'time', 'time handler mapped'); eq(calls[2][2].value, '08:00', 'time argument mapped')
now = now + 3
r = admin.run(s, ALICE, '!cmd stat fps', game())
eq(r.text, 'ran stat fps', 'cmd reply names the line')
eq(calls[#calls][1], 'console', 'cmd maps to the console door')
eq(calls[#calls][2].line, 'stat fps', 'the whole line is passed')
eq(calls[#calls][2].sender.name, 'Alice', 'as the admin')
now = now + 10
r = admin.run(s, ALICE, '!cmd', game())
eq(r.ok, false, 'an empty line is refused'); eq(r.text, 'use: !cmd LINE', 'with the usage')
now = now + 10
r = admin.run(s, ALICE, '!kick Player Two', game())
eq(r.text, 'Player Two removed', 'kick reply')
eq(calls[#calls][1], 'kick', 'kick handler mapped')
eq(calls[#calls][2].player, 'Player Two', 'spaced player preserved')
now = now + 3
r = admin.run(s, ALICE, '!help', game())
eq(#r.text <= 40, true, 'reply at most 40 characters')

now = now + 3
r = admin.run(s, ALICE, '!restart', game())
eq(r.text, 'rename to !confirm within 60 sec', 'restart asks for confirmation')
eq(calls[#calls][1] ~= 'restart', true, 'restart not yet run')
now = now + 3
r = admin.run(s, ALICE, '!confirm', game())
eq(calls[#calls][1], 'restart', 'timely confirmation requests restart')
eq(r.text, 'restart requested', 'restart reply')
now = now + 3
r = admin.run(s, ALICE, '!confirm', game())
eq(r.color, 'red', 'confirmation is one use')
now = now + 3; admin.run(s, ALICE, '!restart', game()); now = now + 61
r = admin.run(s, ALICE, '!confirm', game())
eq(r.text, 'restart confirmation expired', 'confirmation expires after 60 seconds')
now = now + 3
r = admin.run(s, ALICE, '!restart cancel', game())
eq(calls[#calls][1], 'restart_cancel', 'restart cancel is immediate')
eq(r.text, 'restart cancelled', 'restart cancel reply')

if failures > 0 then print(failures .. ' failed'); os.exit(1) end
print('all passed')
