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
eq(p.valid_utf8('plain \226\152\131'), true, 'valid UTF-8')
eq(p.valid_utf8('bad\192\175'), false, 'overlong UTF-8 refused')
eq(p.valid_utf8('bad\237\160\128'), false, 'UTF-8 surrogate refused')
local r = p.result(id, true, {}, nil, '12345')
eq(r.v, 1, 'response version'); eq(r.accepts[1], 1, 'accepted versions')
eq(r.meta.game_build_id, '12345', 'response build'); eq(r.meta.mod_version, p.MOD_VERSION, 'response mod version')
print(string.format('%d tests, %d failures', ran, failed))
os.exit(failed == 0 and 0 or 1)
