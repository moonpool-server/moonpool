-- Empty-server policy for SN2SlotFreeHost. Pure Lua with no game calls, so it is
-- tested outside the game with a stub clock (tests/lua/idle_spec.lua).
-- The game keeps running so joins stay instant; after freeze_s empty the
-- clock is frozen (the command class's FreezeTime), the next join unfreezes
-- it (UnfreezeTime); after stop_s empty (optional) the game process stops.
-- `held` is the operator's own `daylight: frozen` (settings.yaml): while it is
-- set the clock is theirs, so a join never unfreezes it and the empty timer
-- never freezes it again (a frozen clock with a player
-- in was unfrozen 2.8 s later as "a player joined").
local M = {}

-- cfg: { freeze_s = seconds or nil (off), stop_s = seconds or nil (off) }
function M.new(cfg)
  return { freeze_s = cfg.freeze_s, stop_s = cfg.stop_s,
    empty_since = nil, frozen = false, held = false, stopped = false }
end

-- The operator's daylight line: `frozen` holds the clock (held and frozen),
-- `normal` hands it back with the empty timer restarted, so a host that has
-- been empty for an hour does not freeze again on the very next tick.
function M.hold(s, held)
  s.held = held and true or false
  s.frozen = s.held
  if not s.held then s.empty_since = nil end
end

-- One tick: players = joiners online (the host excluded), now = seconds.
-- Returns a list of actions in order: 'freeze', 'unfreeze', 'stop'.
function M.tick(s, players, now)
  local actions = {}
  if players > 0 then
    s.empty_since = nil
    if s.frozen and not s.held then s.frozen = false; actions[#actions + 1] = 'unfreeze' end
    s.stopped = false
    return actions
  end
  if s.empty_since == nil then s.empty_since = now end
  local empty = now - s.empty_since
  if s.freeze_s and not s.frozen and not s.held and empty >= s.freeze_s then
    s.frozen = true; actions[#actions + 1] = 'freeze'
  end
  if s.stop_s and not s.stopped and empty >= s.stop_s then
    s.stopped = true; actions[#actions + 1] = 'stop'
  end
  return actions
end

-- Minutes or hours from the environment; empty, 0 or garbage means off.
function M.seconds(value, unit)
  local n = tonumber(value or '')
  if not n or n <= 0 then return nil end
  return math.floor(n * unit)
end

-- The player limit the admin asks for: real slots 1..63 (the session is
-- hosted at slots + 1, the host counts). Returns the session limit or nil.
function M.session_limit(slots)
  if type(slots) ~= 'number' or slots ~= math.floor(slots) then return nil end
  if slots < 1 or slots > 63 then return nil end
  return slots + 1
end

return M
