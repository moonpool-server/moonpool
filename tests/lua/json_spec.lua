-- The behaviour every caller of json.lua relies on, fixed here so a replacement library can be tried
-- against the same cases: the null marker, empty tables, sorted keys, escapes, numbers, nesting.
package.path = 'mod/MoonpoolHost/Scripts/?.lua;' .. package.path
local json = require('json')
local ran, failed = 0, 0
local function eq(got, want, name)
  ran = ran + 1
  if got == want then print('ok ' .. name); return end
  failed = failed + 1
  print('not ok ' .. name .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
end
local function fails(s, pattern, name)
  local ok, err = pcall(json.decode, s)
  eq(not ok and tostring(err):find(pattern, 1, true) ~= nil, true, name .. ' (' .. tostring(err) .. ')')
end

-- null: decodes to a marker that is not nil, so a key holding null is still there, and encodes back.
local t = json.decode('{"a":null}')
eq(t.a, json.null, 'null decodes to json.null')
eq(json.encode({ a = json.null }), '{"a":null}', 'json.null encodes to null')
eq(json.encode(nil), 'null', 'nil encodes to null')

-- Tables: an empty one is an object; a sequence is an array; anything else is an object with sorted keys.
eq(json.encode({}), '{}', 'empty table is an object')
eq(json.encode({ 1, 2, 3 }), '[1,2,3]', 'sequence is an array')
eq(json.encode({ b = 1, a = 2, c = { 3 } }), '{"a":2,"b":1,"c":[3]}', 'keys sorted')
eq(pcall(json.encode, { [1] = 'x', [3] = 'y' }), false, 'sparse table refused, not guessed')
eq(pcall(json.encode, { [true] = 1 }), false, 'non-string keys refused')
eq(#json.decode('[]'), 0, 'empty array decodes')
eq(next(json.decode('{}')), nil, 'empty object decodes')

-- Strings: control characters escaped, the BMP and astral planes as UTF-8, surrogate pairs joined.
eq(json.encode('a"b\\c\n\t\1'), '"a\\"b\\\\c\\n\\t\\u0001"', 'escapes')
eq(json.decode('"\\u00e9"'), '\u{e9}', 'BMP escape')
eq(json.decode('"\\ud83d\\ude00"'), '\u{1F600}', 'surrogate pair is one character')
eq(json.decode('"\u{1F600}"'), '\u{1F600}', 'raw UTF-8 passes through')
eq(json.decode(json.encode('\u{1F600} é')), '\u{1F600} é', 'UTF-8 round trip')
eq(json.decode('"a\\/b"'), 'a/b', 'escaped slash')
fails('"\\ud83d"', 'surrogate', 'lone high surrogate refused')
fails('"\\ude00"', 'surrogate', 'lone low surrogate refused')
fails('"a\nb"', 'control character', 'raw newline in a string refused')
fails('"abc', 'unterminated', 'unterminated string refused')

-- Numbers: integers stay integers, fractions keep their precision, non-finite numbers are refused.
eq(json.encode(42), '42', 'integer')
eq(json.encode(-0.5), '-0.5', 'fraction')
eq(json.decode(json.encode(0.1)), 0.1, 'fraction round trip')
eq(json.decode('1e3'), 1000, 'exponent')
eq(json.decode('-12.5'), -12.5, 'negative fraction')
eq(pcall(json.encode, 0 / 0), false, 'NaN refused')
eq(pcall(json.encode, math.huge), false, 'infinity refused')

-- Structure: nesting is limited, trailing data and bad input are refused.
eq(type(json.decode(string.rep('[', 32) .. string.rep(']', 32))), 'table', '32 levels allowed')
fails(string.rep('[', 34) .. string.rep(']', 34), 'nesting too deep', 'deeper nesting refused')
fails('{"a":1} x', 'trailing data', 'trailing data refused')
fails('{"a" 1}', 'expected :', 'missing colon refused')
fails('[1 2]', 'expected , or ]', 'missing comma refused')
fails('tru', 'unexpected character', 'bad literal refused')
eq(pcall(json.decode, 5), false, 'non-string input refused')

-- Whitespace and a real message shape.
local m = json.decode(' { "v" : 1 , "args" : [ "a" , { "n" : 2 } ] } ')
eq(m.v == 1 and m.args[1] == 'a' and m.args[2].n == 2, true, 'whitespace and nesting')

print(string.format('%d tests, %d failures', ran, failed))
os.exit(failed == 0 and 0 or 1)
