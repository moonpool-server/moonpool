-- friend_code.lua: the host's Sonar friend code, for players not on Steam.
-- EXPERIMENTAL. The game makes the code only while its Friends screen view
-- model exists (/Script/Subnautica2.SN2InGameFriendScreenViewModel, seen in the
-- function dump), so this uses the one the game made when its
-- Friends screen was opened on the viewer page. It never constructs one: a
-- view model built by the mod belongs to nothing in the game, and the host
-- crashed inside the loader 20 s after a constructed one made a code
-- (a code was made shortly before an access violation in UE4SS.dll). For
-- the same reason no view model is held between ticks; each poll finds it again.
-- Pure Lua; the game calls come in through `g` (tests/lua/friend_code_spec.lua).
local M = {}

M.CLASS = '/Script/Subnautica2.SN2InGameFriendScreenViewModel'
-- Read first, with the loose check below; every other property of the view
-- model is read after them and taken only in the shape of a code.
M.PROPS = { 'FriendCode', 'SonarFriendCode', 'MyFriendCode' }
M.MAX_TICKS = 15
-- A code made by the game read 3647-1991: two groups of four.
M.SHAPE = '^%w%w%w%w%-%w%w%w%w$'

local function loose(v) return type(v) == 'string' and v:match('^%w[%w%-]+$') ~= nil end
function M.is_code(v) return type(v) == 'string' and v:match(M.SHAPE) ~= nil end

-- g: find_vm(), others() -> players in other than the host,
--    call(vm, fname) -> ok, err, read(vm, prop) -> string or nil,
--    props(vm) -> the view model's property names (optional)
function M.start(g, force)
  if not force and (g.others() or 0) > 0 then
    return nil, 'players_online' -- the screen belongs to a quiet host only
  end
  local vm = g.find_vm()
  if not vm then return nil, 'no_view_model' end
  local ok, err = g.call(vm, 'RequestFriendCode')
  if not ok then return nil, 'request_failed: ' .. tostring(err) end
  return { ticks = 0 }
end

-- One poll: the code (and the property it came from), or nil while waiting,
-- or nil plus 'view_model_gone' (the screen closed) or 'timeout'.
function M.poll(g, job)
  job.ticks = job.ticks + 1
  local vm = g.find_vm()
  if not vm then return nil, 'view_model_gone' end
  local named = {}
  for _, p in ipairs(M.PROPS) do
    named[p] = true
    local v = g.read(vm, p)
    if loose(v) then return v, p end
  end
  for _, p in ipairs(g.props and g.props(vm) or {}) do
    if not named[p] then
      local v = g.read(vm, p)
      if M.is_code(v) then return v, p end
    end
  end
  if job.ticks >= M.MAX_TICKS then return nil, 'timeout' end
  return nil
end

return M
