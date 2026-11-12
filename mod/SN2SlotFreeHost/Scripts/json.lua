-- Minimal JSON encode/decode for SN2SlotFreeHost (UE4SS ships no JSON library).
-- Handles objects, arrays, strings (with \uXXXX for the BMP), numbers, true,
-- false and null. Original code, MIT licensed with the rest of this project.
local M = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

function M.encode(v)
  local t = type(v)
  if v == nil or v == M.null then return 'null'
  elseif t == 'boolean' then return tostring(v)
  elseif t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then error('json: cannot encode ' .. tostring(v)) end
    if v % 1 == 0 and math.abs(v) < 2^53 then return string.format('%d', v) end
    return string.format('%.17g', v)
  elseif t == 'string' then return encode_string(v)
  elseif t == 'table' then
    local arr, n = is_array(v)
    local out = {}
    if arr and n > 0 then
      for i = 1, n do out[i] = M.encode(v[i]) end
      return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= 'string' then error('json: object keys must be strings') end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do out[i] = encode_string(k) .. ':' .. M.encode(v[k]) end
    return '{' .. table.concat(out, ',') .. '}'
  end
  error('json: cannot encode type ' .. t)
end

M.null = setmetatable({}, { __tostring = function() return 'null' end })

local function decode_error(s, i, msg)
  error(string.format('json: %s at position %d near %q', msg, i, s:sub(i, i + 10)), 0)
end

local function skip(s, i)
  return s:find('[^ \t\r\n]', i) or #s + 1
end

local decode_value

local function decode_string(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == '' then decode_error(s, i, 'unterminated string') end
    if c == '"' then return table.concat(out), j + 1 end
    if c == '\\' then
      local e = s:sub(j + 1, j + 1)
      local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
      if map[e] then out[#out + 1] = map[e]; j = j + 2
      elseif e == 'u' then
        local hex = s:sub(j + 2, j + 5)
        if not hex:match('^%x%x%x%x$') then decode_error(s, j, 'bad \\u escape') end
        out[#out + 1] = utf8.char(tonumber(hex, 16)); j = j + 6
      else decode_error(s, j, 'bad escape') end
    elseif c:byte() < 0x20 then decode_error(s, j, 'control character in string')
    else out[#out + 1] = c; j = j + 1 end
  end
end

decode_value = function(s, i, depth)
  if depth > 32 then decode_error(s, i, 'nesting too deep') end
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == '{' then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then decode_error(s, i, 'expected key') end
      local k; k, i = decode_string(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ':' then decode_error(s, i, 'expected :') end
      obj[k], i = decode_value(s, i + 1, depth + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == '}' then return obj, i + 1 end
      if d ~= ',' then decode_error(s, i, 'expected , or }') end
      i = skip(s, i + 1)
    end
  elseif c == '[' then
    local arr = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
      arr[#arr + 1], i = decode_value(s, i, depth + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == ']' then return arr, i + 1 end
      if d ~= ',' then decode_error(s, i, 'expected , or ]') end
      i = i + 1
    end
  elseif c == '"' then return decode_string(s, i)
  elseif s:sub(i, i + 3) == 'true' then return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then return false, i + 5
  elseif s:sub(i, i + 3) == 'null' then return M.null, i + 4
  end
  local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
  if num and #num > 0 and tonumber(num) then return tonumber(num), i + #num end
  decode_error(s, i, 'unexpected character')
end

function M.decode(s)
  if type(s) ~= 'string' then error('json: expected a string', 0) end
  local v, i = decode_value(s, 1, 0)
  i = skip(s, i)
  if i <= #s then decode_error(s, i, 'trailing data') end
  return v
end

return M
