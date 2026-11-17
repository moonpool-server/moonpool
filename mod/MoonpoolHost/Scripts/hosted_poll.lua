-- UE4SS has timers and object notifications, but no dirty/safety gate
-- for keeping expensive game-object walks out of a steady-state timer.
local M = {}

function M.new(game)
  return { game = game, dirty = true, checked_at = -game.safety_s, paths = {} }
end

function M.mark_dirty(state) state.dirty = true end

local function stale(state)
  if state.dirty or state.game.now() - state.checked_at >= state.game.safety_s then return true end
  for _, path in ipairs(state.paths) do
    if not state.game.valid(state.game.find(path)) then state.dirty = true; return true end
  end
  return false
end

function M.tick(state)
  state.game.hold()
  if not stale(state) then return false end
  local paths = state.game.refresh() or {}
  state.paths, state.dirty, state.checked_at = paths, false, state.game.now()
  state.game.replay()
  return true
end

return M
