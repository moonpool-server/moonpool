-- audit.lua: one JSON line per admin line the server handled, appended to the data volume's
-- logs/admin-audit.log: when, who (name and EOS id), the line, and what came of it.
local json = require('json')
local M = {}

-- The line for one entry. result is a short word (ran, refused, dropped); said is what the server
-- answered, if anything (a list of lines or a string).
function M.entry(now, who, eos, line, result, said)
  if type(said) == 'table' then said = table.concat(said, ' | ') end
  return json.encode({ at = os.date('!%Y-%m-%dT%H:%M:%SZ', now), who = tostring(who or '?'),
    eos = eos and tostring(eos) or nil, line = tostring(line or ''), result = tostring(result or '?'),
    said = said and said ~= '' and tostring(said) or nil })
end

-- Appends an entry's line to path. A write that fails is reported, never raised.
function M.append(path, text)
  local ok, err = pcall(function()
    local f = assert(io.open(path, 'a'))
    f:write(text, '\n')
    f:close()
  end)
  return ok, err
end

return M
