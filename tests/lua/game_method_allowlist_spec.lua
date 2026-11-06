-- Guard against guessed UObject calls returning to crash-sensitive modules.
local allowed = {
  ['voice_range.lua'] = { add=true, move=true, remove=true },
}
local failures = 0
for file, names in pairs(allowed) do
  local path = 'mod/SN2SlotFreeHost/Scripts/' .. file
  local f = assert(io.open(path, 'r')); local source = f:read('*a'); f:close()
  for method in source:gmatch(':%s*([%a_][%w_]*)%s*%(') do
    if not names[method] then failures=failures+1; print('not ok '..file..' calls '..method) end
  end
end
if failures > 0 then os.exit(1) end
print('ok UObject method allowlist')
