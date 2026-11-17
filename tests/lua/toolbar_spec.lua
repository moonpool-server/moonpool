-- Tests for mod/MoonpoolHost/Scripts/toolbar.lua.
package.path = 'mod/MoonpoolHost/Scripts/?.lua;' .. package.path
local toolbar = require('toolbar')
local failures = 0
local function check(cond, what)
  if cond then print('ok ' .. what) else failures = failures + 1; print('not ok ' .. what) end
end

check(toolbar.want(10, 10, 8) == 10, 'a slot mod base of 10 capped at 8 goes to 10')
check(toolbar.want(10, 8, 8) == nil, 'with no slot mod (base 8) nothing changes')
check(toolbar.want(10, 12, 8) == 10, 'never past the setting')
check(toolbar.want(10, 10, 10) == nil, 'a player already at the count is left alone')
check(toolbar.want(10, 10, 11) == nil, 'a count is never lowered')
check(toolbar.want(nil, 10, 8) == nil and toolbar.want('', 10, 8) == nil and toolbar.want(0, 10, 8) == nil,
  'no setting, nothing changes')

local calls = {}
local game = {
  read = function(p) return p end,
  set_cap = function(_, n) calls[#calls + 1] = 'cap ' .. n end,
  set_count = function(_, n) calls[#calls + 1] = 'count ' .. n end,
}
check(toolbar.apply(10, { base = 10, now = 8, cap = 8 }, game) == 10 and table.concat(calls, ',') == 'cap 10,count 10',
  'the cap is raised before the count is set')
calls = {}
check(toolbar.apply(10, { base = 10, now = 8, cap = 12 }, game) == 10 and table.concat(calls, ',') == 'count 10',
  'a cap already high enough is left')
calls = {}
check(toolbar.apply(10, { base = 8, now = 8, cap = 8 }, game) == nil and #calls == 0, 'nothing to do, nothing written')
check(toolbar.apply(10, nil, { read = function() return nil end }) == nil, 'a character that cannot be read is skipped')

if failures > 0 then print(failures .. ' failed'); os.exit(1) end
print('toolbar: ok')
