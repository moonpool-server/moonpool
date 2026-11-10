-- cinematic_hold.lua: hold new joins while the lifepod launch cinematic plays. The game has no
-- join handler the mod can reach, so while the log's Gamestate.LifepodAscending tag is set the
-- session limit is the players already in, and the game's own "session full" turns a joiner away.
-- Pure Lua, no game calls. Original code, MIT.
local M = {}

M.TAG = 'Gamestate.LifepodAscending'
M.ADD = 'Adding global tag ' .. M.TAG
M.REMOVE = 'Removing global tag ' .. M.TAG
-- The ascent takes about a minute; a missed "Removing" line must not keep the server closed.
M.MAX_HOLD_S = 180
M.NOTICE = 'a launch cinematic is playing, join in about a minute'

function M.new(opts)
  opts = opts or {}
  return { held = false, since = nil, max_hold_s = opts.max_hold_s or M.MAX_HOLD_S }
end

local function plain_find(s, needle) return s:find(needle, 1, true) ~= nil end

-- One game-log line: a list of { 'close' | 'open', reason } actions.
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

function M.tick(s, now)
  if s.held and now - s.since >= s.max_hold_s then
    s.held, s.since = false, nil
    return { { 'open', 'tag ' .. M.TAG .. ' not cleared after ' .. s.max_hold_s .. ' s; releasing' } }
  end
  return {}
end

-- Nobody new fits and nobody in is dropped; in_session counts the host's own player.
function M.hold_limit(in_session)
  local n = tonumber(in_session) or 1
  if n < 1 then n = 1 end
  return math.floor(n)
end

-- New log text split into lines; a partial last line waits for the next call.
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
