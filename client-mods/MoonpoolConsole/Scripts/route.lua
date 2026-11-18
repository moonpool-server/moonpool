-- The palette's decisions, with no game calls: where a typed line goes, the count at the end of a search,
-- the history, messages and settings.
local M = { GAME = 'game', CONSOLE = 'console' }

local function first_word(line) return (tostring(line or ''):match('^%s*(%S+)') or ''):lower() end

-- Where a line typed in the panel goes.
--   M.GAME: one of the game's own commands; the game runs it and sends it to the server itself.
--   M.CONSOLE, text: anything else goes to the server's console, led by the word it listens for.
--   nil: nothing was typed.
-- known: the game's command names in lower case, or nil when they could not be read; then every
-- line goes to the console, which passes a game command through as typed.
function M.route(line, known, word)
  local first = first_word(line)
  if first == '' then return nil end
  if first == tostring(word):lower() then return M.CONSOLE, line end
  if known and known[first] then return M.GAME end
  return M.CONSOLE, word .. ' ' .. line
end

-- A filter that ends in a number is a search and a count: "glass 10" finds Glass, 10 of it. Returns
-- the search and the count (nil when there is none).
function M.count(query)
  local search, n = tostring(query):match('^(.-)%s+(%d+)%s*$')
  n = tonumber(n)
  if not n or n < 1 then return tostring(query), nil end
  return search, math.floor(n)
end

-- The lines run from the palette, newest first: line goes to the front, once, and the list keeps at
-- most max of them.
function M.remember(recent, line, max)
  line = tostring(line or ''):match('^%s*(.-)%s*$')
  if line == '' then return recent end
  local out = { line }
  for _, l in ipairs(recent or {}) do
    if l ~= line and #out < (max or 50) then out[#out + 1] = l end
  end
  return out
end

-- A message with its {names} filled in from values.
function M.fill(template, values)
  return (tostring(template):gsub('{(%w+)}', function(k) return tostring((values or {})[k]) end))
end

-- base with over's values laid on top, table by table: a player's own settings change only the keys
-- they name. A list (a table with [1]) is replaced whole.
function M.merge(base, over)
  if type(over) ~= 'table' then return base end
  for k, v in pairs(over) do
    if type(v) == 'table' and type(base[k]) == 'table' and v[1] == nil then M.merge(base[k], v) else base[k] = v end
  end
  return base
end

return M
