package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local p = require('protocol')
local ran, failed = 0, 0
local function eq(got, want, name)
  ran = ran + 1
  if got ~= want then failed = failed + 1; print('not ok ' .. name .. ': ' .. tostring(got))
  else print('ok ' .. name) end
end
local enabled = {}; for k in pairs(p.ALLOWLIST) do enabled[k] = true end
local function msg(id, overrides)
  local m = { v = 1, id = id, cmd = 'players', args = {}, ts = 1000 }
  for k, v in pairs(overrides or {}) do m[k] = v end
  return m
end
local id = '0123456789abcdef0123456789abcdef'
local seen = p.new_seen()
eq(p.validate(msg(id), id .. '.json', 1000, enabled, seen), 'players', 'valid request')
eq(select(2, p.validate(msg(id), id .. '.json', 1000, enabled, seen)), 'replay', 'duplicate nonce')
eq(select(2, p.validate(msg('1123456789abcdef', { ts = 800 }),
  '1123456789abcdef.json', 1000, enabled, p.new_seen())), 'stale', 'stale request')
eq(select(2, p.validate(msg('2123456789abcdef', { v = 2 }),
  '2123456789abcdef.json', 1000, enabled, p.new_seen())), 'bad_version', 'version mismatch')
-- The replay guard keeps a nonce exactly as long as its request could pass the age check.
local function nonce(i) return string.format('%016x', i) end
local function try(s, i, ts, now)
  local cmd, err = p.validate(msg(nonce(i), { ts = ts }), nonce(i) .. '.json', now, enabled, s)
  return cmd and 'ok' or err
end
local g = p.new_seen({}, 0)
local accepted = 0
for i = 1, 1000 do if try(g, i, 1000, 1000) == 'ok' then accepted = accepted + 1 end end
eq(accepted, 1000, 'a thousand fresh nonces are accepted')
eq(g.count(), 1000, 'a thousand nonces held inside the window')
eq(try(g, 1, 1000, 1000 + p.MAX_AGE_SECONDS), 'replay', 'a replay at the last accepted second is refused')
eq(try(g, 1, 1100, 1000 + p.MAX_AGE_SECONDS), 'replay', 'a replay with a new timestamp is refused')
eq(try(g, 2001, 2000, 2000), 'ok', 'a later request is accepted')
eq(g.count(), 1, 'nonces whose requests can no longer pass are let go')
eq(try(g, 1, 1000, 2000), 'stale', 'and their requests are still refused, as stale')
eq(try(g, 2001, 2000, 2000 + p.MAX_AGE_SECONDS), 'replay', 'the later nonce is still held')
local future = p.new_seen({}, 0)
eq(try(future, 7, 1100, 1000), 'ok', 'a request stamped ahead of the clock is accepted')
eq(try(future, 7, 1100, 1000 + 200), 'replay', 'and held until its own timestamp ages out')
local restarted = p.new_seen({ nonce(9) }, 5000)
eq(try(restarted, 9, 5000 + p.MAX_AGE_SECONDS, 5000 + p.MAX_AGE_SECONDS), 'replay',
  'a nonce from before a restart is held while its request could still pass')
eq(try(restarted, 10, 5300, 5300), 'ok', 'a request after both windows is accepted')
eq(restarted.count(), 1, 'and a nonce from before the restart is let go after both windows')

eq(p.valid_utf8('plain \226\152\131'), true, 'valid UTF-8')
eq(p.valid_utf8('bad\192\175'), false, 'overlong UTF-8 refused')
eq(p.valid_utf8('bad\237\160\128'), false, 'UTF-8 surrogate refused')
local r = p.result(id, true, {}, nil, '12345')
eq(r.v, 1, 'response version'); eq(r.accepts[1], 1, 'accepted versions')
eq(r.meta.game_build_id, '12345', 'response build'); eq(r.meta.mod_version, p.MOD_VERSION, 'response mod version')
print(string.format('%d tests, %d failures', ran, failed))
os.exit(failed == 0 and 0 or 1)
