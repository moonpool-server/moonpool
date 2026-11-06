-- cinematic_hold.lua: hold new joins while the lifepod launch cinematic plays.
-- What nothing else provides: the game has no join handler the mod can reach
-- by name (no PreLogin/ApproveLogin/lobby join UFunction in the reflected
-- names, services_functions.txt), and its global-tag functions take either a
-- tag struct (HasGlobalTag) or act on the one global set (RemoveGlobalTag
-- TagName), so removing the tag "for everyone but the launcher" is not
-- possible by name. What IS reachable and already proven is the session
-- limit write (set_limits / moonpool slots). So while the tag is set the limit
-- is lowered to the players already in, and the game's own "session full"
-- refusal turns a joiner away; when the tag clears the limit goes back.
-- The tag is read from the game's own log lines:
--   "Adding global tag Gamestate.LifepodAscending"
--   "Removing global tag Gamestate.LifepodAscending"
-- Pure Lua, no game calls: recipe.lua feeds it lines and the clock and acts on
-- what it returns. Original code, MIT.
local M = {}

M.TAG = 'Gamestate.LifepodAscending'
M.ADD = 'Adding global tag ' .. M.TAG
M.REMOVE = 'Removing global tag ' .. M.TAG
-- The ascent took 58 s; a missed "Removing" line must not keep the
-- server closed, so the hold lets go by itself after this long.
M.MAX_HOLD_S = 180
M.NOTICE = 'a launch cinematic is playing, join in about a minute'

function M.new(opts)
  opts = opts or {}
  return { held = false, since = nil, max_hold_s = opts.max_hold_s or M.MAX_HOLD_S }
end

local function plain_find(s, needle) return s:find(needle, 1, true) ~= nil end

-- One game-log line. Returns a list of actions:
--   { 'close', reason }   lower the limit to the players in now
--   { 'open', reason }    put the configured limit back
function M.line(s, line, now)
  local acts = {}
  if plain_find(line, M.ADD) and not s.held then
    s.held, s.since = true, now
    acts[#acts + 1] = { 'close', 'tag ' .. M.TAG .. ' added' }
  elseif plain_find(line, M.REMOVE) and s.held then
    s.held, s.since = false, nil
    acts[#acts + 1] = { 'open', 'tag ' .. M.TAG .. ' cleared' }
  end
  return acts
end

-- The clock, once per poll: the safety release.
function M.tick(s, now)
  if s.held and now - s.since >= s.max_hold_s then
    s.held, s.since = false, nil
    return { { 'open', 'tag ' .. M.TAG .. ' not cleared after ' .. s.max_hold_s .. ' s; releasing' } }
  end
  return {}
end

-- The limit to write while held: nobody new fits, nobody in is dropped.
-- in_session counts the host's own player too (it holds a slot).
function M.hold_limit(in_session)
  local n = tonumber(in_session) or 1
  if n < 1 then n = 1 end
  return math.floor(n)
end

-- New text appended to a log since the last read, split into lines; keeps a
-- partial last line for the next call. pos is a byte offset.
function M.split_new(buf, chunk)
  buf = (buf or '') .. (chunk or '')
  local lines = {}
  local start = 1
  while true do
    local i = buf:find('\n', start, true)
    if not i then break end
    lines[#lines + 1] = buf:sub(start, i - 1):gsub('\r$', '')
    start = i + 1
  end
  return lines, buf:sub(start)
end

return M
