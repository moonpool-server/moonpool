-- Tests for mod/MoonpoolHost/Scripts/audit.lua: the admin audit log's lines.
--   lua5.4 tests/lua/audit_spec.lua   (from the repository root)
package.path = 'mod/MoonpoolHost/Scripts/?.lua;' .. package.path
local audit = require('audit')
local json = require('json')

local failures = 0
local function check(cond, what)
  if cond then print('ok ' .. what) else failures = failures + 1; print('not ok ' .. what) end
end

local e = json.decode(audit.entry(0, 'dirtbikr59', 'abc', 'Item DA_Glass_ItemType 10', 'ran', { 'one', 'two' }))
check(e.at == '1970-01-01T00:00:00Z' and e.who == 'dirtbikr59' and e.eos == 'abc',
  'an entry says when, in UTC, and who')
check(e.line == 'Item DA_Glass_ItemType 10' and e.result == 'ran' and e.said == 'one | two',
  'it says the line, what came of it and what the server answered')
local bare = json.decode(audit.entry(0, nil, nil, 'God', 'refused'))
check(bare.who == '?' and bare.eos == nil and bare.said == nil,
  'a sender with no id and no answer still makes a line')
check(not audit.entry(0, 'a', 'b', 'x\ny', 'ran'):find('\n', 1, true),
  'a line break in the line cannot start a new entry')

local path = os.tmpname()
check(audit.append(path, 'first') and audit.append(path, 'second'), 'entries are appended')
local f = io.open(path); local text = f:read('a'); f:close(); os.remove(path)
check(text == 'first\nsecond\n', 'one entry per line, in order')
check(not audit.append('/no/such/dir/audit.log', 'x'), 'a write that fails is reported, not raised')

if failures > 0 then os.exit(1) end
print('audit: ok')
