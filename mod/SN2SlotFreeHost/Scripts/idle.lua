-- Empty-server policy; pure Lua, no game calls. After freeze_s empty the clock freezes and the
-- next join unfreezes it; after stop_s empty the game stops. While the operator's
-- `daylight: frozen` holds the clock, neither touches it.
local M = {}

-- cfg: { freeze_s = seconds or nil (off), stop_s = seconds or nil (off) }
function M.new(cfg)
  return { freeze_s = cfg.freeze_s, stop_s = cfg.stop_s,
    empty_since = nil, frozen = false, held = false, stopped = false }
end

-- `normal` hands the clock back with the empty timer restarted.
function M.hold(s, held)
  s.held = held and true or false
  s.frozen = s.held
  if not s.held then s.empty_since = nil end
end

-- players = joiners online, host excluded. Returns 'freeze', 'unfreeze' and 'stop' actions.
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

-- Real slots 1..63 to the session limit (the host counts), or nil.
function M.session_limit(slots)
  if type(slots) ~= 'number' or slots ~= math.floor(slots) then return nil end
  if slots < 1 or slots > 63 then return nil end
  return slots + 1
end

return M
