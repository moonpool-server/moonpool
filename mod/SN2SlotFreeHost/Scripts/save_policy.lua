-- When the host saves the world; pure Lua, no game calls. With every_s set, the game's own
-- autosave (every 2 minutes, a server stall each time) is switched off and the host saves on
-- its own schedule instead: every every_s seconds and once after each batch of players leaves.
-- ToggleAutoSave is a toggle, so it is sent only right after a game autosave was seen, which
-- proves autosave is on; a save the host itself asked for logs the same line, so lines within
-- OWN_SAVE_S of the host's own request are not counted as the game's.
local M = {}

M.OWN_SAVE_S = 90      -- a requested save's autosave_completed line arrives well within this
M.RETOGGLE_S = 180     -- after a toggle, the next game autosave proves it did not take

-- cfg: { every_s = seconds or nil (off: the game's autosave is left alone) }
function M.new(cfg)
  return { every_s = cfg.every_s, last_save = nil, last_request = nil, last_toggle = nil,
    present = nil, autosave_off = false }
end

-- now: seconds; up: the world is loaded and hosted; players: names online, host excluded;
-- autosaves: how many autosave_completed lines the game log gained since the last tick.
-- Returns actions: 'autosave_off' (send ToggleAutoSave as the host) and 'save'.
function M.tick(s, now, up, players, autosaves)
  local actions = {}
  if not s.every_s or not up then
    s.present = nil
    return actions
  end
  if s.last_save == nil then s.last_save = now end
  -- A game autosave seen away from the host's own requests: autosave is on.
  if (autosaves or 0) > 0 and not (s.last_request and now - s.last_request < M.OWN_SAVE_S) then
    s.autosave_off = false
    if not s.last_toggle or now - s.last_toggle >= M.RETOGGLE_S then
      s.last_toggle = now
      s.autosave_off = true
      actions[#actions + 1] = 'autosave_off'
    end
  end
  local left = false
  local here = {}
  for _, name in ipairs(players or {}) do here[name] = true end
  if s.present then
    for name in pairs(s.present) do
      if not here[name] then left = true end
    end
  end
  s.present = here
  if left or now - s.last_save >= s.every_s then
    s.last_save, s.last_request = now, now
    actions[#actions + 1] = 'save'
  end
  return actions
end

return M
