-- friend_code.lua: the host's Sonar friend code, for players not on Steam.
-- EXPERIMENTAL. The game makes the code only while its Friends screen view
-- model exists (/Script/Subnautica2.SN2InGameFriendScreenViewModel, seen in the
-- function dump). A headless host has no screen to click, so when none is open
-- the game's own Friends screen widget is built for the host's player and added
-- to the viewport (g.open_screen): the widget makes and owns the view model, the
-- way a click does. The mod never constructs a view model itself: one built by
-- the mod belongs to nothing in the game, and the host crashed inside the loader
-- 20 s after a constructed one made a code. No view model is held between ticks;
-- each poll finds it again, and a screen this module opened is closed by finish.
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
--    props(vm) -> the view model's property names (optional),
--    open_screen() -> ok, why and close_screen() (optional: a host with no screen)
function M.start(g, force)
  if not force and (g.others() or 0) > 0 then
    return nil, 'players_online' -- the screen belongs to a quiet host only
  end
  local job = { ticks = 0, requested = false, how = 'found' }
  local vm = g.find_vm()
  if not vm then
    if not g.open_screen then return nil, 'no_view_model' end
    local ok, why = g.open_screen()
    if not ok then return nil, 'open_failed: ' .. tostring(why) end
    job.opened, job.how = true, 'opened'
    vm = g.find_vm()
  end
  if vm then
    local ok, err = g.call(vm, 'RequestFriendCode')
    if not ok then M.finish(g, job); return nil, 'request_failed: ' .. tostring(err) end
    job.requested = true
  end
  return job
end

-- Closes a screen start opened; nothing otherwise.
function M.finish(g, job)
  if job and job.opened and g.close_screen then g.close_screen() end
end

-- One poll: the code (and the property it came from), or nil while waiting,
-- or nil plus 'view_model_gone' (the screen closed) or 'timeout'.
function M.poll(g, job)
  job.ticks = job.ticks + 1
  local vm = g.find_vm()
  if not vm then
    if job.requested then return nil, 'view_model_gone' end
    if job.ticks >= M.MAX_TICKS then return nil, 'timeout' end
    return nil -- a screen just opened is still being built
  end
  if not job.requested then
    if g.call(vm, 'RequestFriendCode') then job.requested = true end
    return nil
  end
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
