-- Shared helpers for the mod's modules: logging, files, names, console lines and controller lookup.
local status = require('status')

local M = {}

local TAG = '[SN2SlotFreeHost] '
local function log(msg) print(TAG .. msg .. '\n') end
M.log = log

local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
M.valid = valid

function M.read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function to_str(v)
  if v == nil then return nil end
  if type(v) == 'string' then return v end
  local ok, s = pcall(function() return v:ToString() end)
  if ok then return s end
  return tostring(v)
end
M.to_str = to_str

local DIR
function M.configure(opts) DIR = opts.dir end
function M.cpath(...) return DIR .. '\\' .. table.concat({ ... }, '\\') end

-- GetPlayerName() answers nothing on the live build; PlayerNamePrivate does.
function M.ps_name(ps)
  local name
  pcall(function() name = to_str(ps:GetPlayerName()) end)
  if not name or name == '' then pcall(function() name = ps.PlayerNamePrivate:ToString() end) end
  if name == '' then name = nil end
  return name
end

-- A console line run server-side as that player; the game's reply goes to its own log.
function M.run_as(pc, line, why)
  log('console as ' .. why .. ': ' .. line .. ' (game reply lines follow in the game log)')
  ExecuteInGameThread(function()
    local ksl = StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    local ok, err = pcall(function() ksl:ExecuteConsoleCommand(pc:GetWorld(), line, pc) end)
    if not ok then log('console as ' .. why .. ' failed: ' .. tostring(err)) end
  end)
end

-- Controller lookup by name through a path cache the roster rebuild replaces; a miss falls back
-- to one FindAllOf unless cached_only.
local controller_paths = {}
function M.set_controller_cache(tbl) controller_paths = tbl end
function M.controller_named(name, cached_only)
  local path = controller_paths[name]
  local pc
  if path then pcall(function() pc = StaticFindObject(path) end) end
  if valid(pc) then return pc end
  if cached_only then return nil end
  local ok, all = pcall(FindAllOf, 'PlayerController')
  if not ok or not all then return nil end
  for _, found in ipairs(all) do
    if valid(found) then
      local found_name, found_path
      pcall(function() found_name = M.ps_name(found.PlayerState); found_path = status.object_path(found) end)
      if found_name and found_path then controller_paths[found_name] = found_path end
      if found_name == name then pc = found end
    end
  end
  return valid(pc) and pc or nil
end

return M
