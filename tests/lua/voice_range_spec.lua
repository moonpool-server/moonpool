-- Pure-Lua coverage for private voice-range signals and their lifecycle.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local voice = require('voice_range')
local failures = 0
local function eq(got, want, what)
  if got ~= want then failures = failures + 1; print('not ok ' .. what .. ': got [' .. tostring(got)
    .. '] want [' .. tostring(want) .. ']') else print('ok ' .. what) end
end

local calls, next_id = {}, 0
local store = {}
function store.add(_, listener, target, label, pos, color, tracking)
  next_id = next_id + 1
  calls[#calls + 1] = { 'add', next_id, listener.name, target.name, label, pos, color, tracking }
  return next_id
end
function store.move(_, id, pos) calls[#calls + 1] = { 'move', id, pos } end
function store.remove(_, id) calls[#calls + 1] = { 'remove', id } end
local function p(name, metres) return { name = name, x = metres * 100, y = 0, z = 0, player = name } end
local function count(kind)
  local n = 0; for _, c in ipairs(calls) do if c[1] == kind then n = n + 1 end end; return n
end

local s = voice.new({ range_m = 100, hysteresis_m = 10, host = 'Host' })
voice.update(s, { p('Alice', 0), p('Bob', 101), p('Host', 1000) }, store)
eq(count('add'), 2, 'crossing range adds one private signal in each direction')
eq(calls[1][5], 'Bob · out of voice range', 'signal names the distant friend')
eq(calls[1][7].R, 1.0, 'signal is amber')
eq(calls[1][8], 'Bob', 'signal tracks the distant player')
eq(next(s.signals) ~= nil, true, 'active pair is remembered')

calls = {}
voice.update(s, { p('Alice', 0), p('Bob', 99), p('Host', 1000) }, store)
eq(count('remove'), 0, 'hysteresis keeps signals just inside the outer edge')
eq(count('move'), 2, 'both private signals move with their targets')
calls = {}
voice.update(s, { p('Alice', 0), p('Bob', 89) }, store)
eq(count('remove'), 2, 'signals clear inside the restore threshold')

calls = {}
voice.update(s, { p('Alice', 0), p('Bob', 150) }, store)
calls = {}
voice.update(s, { p('Alice', 0) }, store)
eq(count('remove'), 2, 'both signals clear when either player leaves')

calls = {}
voice.update(s, { p('Host', 0), p('Alice', 150) }, store)
eq(count('add'), 0, 'host account never receives or causes a signal')
voice.update(s, { { name = 'Alice' }, p('Bob', 150), { name = '?', x = 0, y = 0, z = 0 } }, store)
eq(count('add'), 0, 'players without positions and unnamed states are ignored')

voice.update(s, { p('Alice', 0), p('Bob', 150) }, store)
calls = {}; voice.clear(s, store)
eq(count('remove'), 2, 'clear removes every live signal')

if failures > 0 then print(failures .. ' failed'); os.exit(1) end
print('all passed')
