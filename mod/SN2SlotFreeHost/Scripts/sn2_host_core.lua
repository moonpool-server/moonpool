-- SN2SlotFreeHost host-core: the primitives a feature plugin builds on.
--
-- Pure helpers (log, valid, read_file, to_str, cpath) and the two console
-- primitives that carry no shared state (ps_name, run_as), plus on_game_thread
-- so a plugin can schedule its own game-thread work. Everything here is
-- self-contained: UE4SS globals (ExecuteInGameThread, StaticFindObject) and the
-- Lua stdlib only, never a recipe.lua local. The control directory is the one
-- runtime input, handed over through configure() once recipe.lua resolves it.
--
-- controller_named / player_pawn and the controller path cache live here too;
-- the roster rebuild in recipe.lua pushes its rebuilt map in through
-- set_controller_cache(), so the cache has a single owner.

local status = require('status')

local M = {}

local TAG = '[SN2SlotFreeHost] '
local function log(msg) print(TAG .. msg .. '\n') end
M.log = log

-- A UObject that is non-nil and still alive this frame.
local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
M.valid = valid

-- Whole file as a binary string, or nil when it is not there.
function M.read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

-- A UObject (or FString) to a plain Lua string; nil stays nil.
local function to_str(v)
  if v == nil then return nil end
  if type(v) == 'string' then return v end
  local ok, s = pcall(function() return v:ToString() end)
  if ok then return s end
  return tostring(v)
end
M.to_str = to_str

-- The control directory the launcher exports (SN2_CONTROL_WIN) or config
-- overrides. recipe.lua resolves it once at startup and hands it over here.
local DIR
function M.configure(opts) DIR = opts.dir end
function M.cpath(...) return DIR .. '\\' .. table.concat({ ... }, '\\') end

-- A player state's name. GetPlayerName() answers nothing on the live build
-- (every player listed as '?', every per-player command
-- unknown_player, the join replay never saw a name), while the state's own
-- PlayerNamePrivate does; status.lua and main.lua already read it that way.
-- Nil when neither answers.
function M.ps_name(ps)
  local name
  pcall(function() name = to_str(ps:GetPlayerName()) end)
  if not name or name == '' then pcall(function() name = ps.PlayerNamePrivate:ToString() end) end
  if name == '' then name = nil end
  return name
end

-- Run a console line server-side as a specific player controller. The game's
-- own reply lines go to its log, not here.
function M.run_as(pc, line, why)
  log('console as ' .. why .. ': ' .. line .. ' (game reply lines follow in the game log)')
  ExecuteInGameThread(function()
    local ksl = StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    local ok, err = pcall(function() ksl:ExecuteConsoleCommand(pc:GetWorld(), line, pc) end)
    if not ok then log('console as ' .. why .. ' failed: ' .. tostring(err)) end
  end)
end

-- Schedule a function on the game thread. Anything that touches UObjects a
-- plugin must run here, not on the poll thread.
function M.on_game_thread(fn) ExecuteInGameThread(fn) end

-- Player-controller lookup by name, with a path cache. The change-driven
-- roster rebuild in recipe.lua owns the cache's contents and replaces the
-- whole table through set_controller_cache(); a command that arrives before
-- the roster has seen a controller falls back to one bounded FindAllOf and
-- seeds the cache for next time (cached_only skips that fallback).
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

-- The pawn of a named player's controller, nil when it has none alive.
function M.player_pawn(name)
  local pc = M.controller_named(name)
  local pawn
  if pc then pcall(function() pawn = pc.Pawn end) end
  if not valid(pawn) and pc then pcall(function() pawn = pc.PlayerState.PawnPrivate end) end
  return valid(pawn) and pawn or nil
end

return M
