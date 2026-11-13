-- The panel's decisions, with no game calls: where a typed line goes and which parts of the panel show.
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

-- Whether text answers a typed query: every word of the query is in the text as written, in any
-- order ("ing tit" finds Titanium Ingot). With loose, a typed word's letters only have to appear in
-- order inside one word that starts with the same letter ("tnm" finds Titanium): for a slip of the
-- finger, used when nothing answers as written. An empty query matches everything.
function M.matches(text, query, loose)
  text = tostring(text):lower()
  for word in tostring(query):lower():gmatch('%S+') do
    if not loose then
      if not text:find(word, 1, true) then return false end
    else
      local found = false
      for part in text:gmatch('%S+') do  -- within one word of the text, starting with its first letter
        local at = part:sub(1, 1) == word:sub(1, 1) and 1 or nil
        for letter in word:gmatch('.') do
          at = at and part:find(letter, at, true)
          if not at then break end
          at = at + 1
        end
        found = found or at ~= nil
      end
      if not found then return false end
    end
  end
  return true
end

-- What a list row is searched by: the item's own name and its name in the game's data, without the
-- parts every such name shares (patterns from the settings).
function M.search_text(id, label, strip)
  for _, pattern in ipairs(strip or {}) do id = id:gsub(pattern, '') end
  return label .. ' ' .. id
end

-- A message with its {names} filled in from values.
function M.fill(template, values)
  return (tostring(template):gsub('{(%w+)}', function(k) return tostring((values or {})[k]) end))
end

-- Whether a part of the panel is hidden: its kind is listed under hide and its name is not under keep.
function M.hidden(kind, part, rules)
  local hide, keep = false, false
  for _, k in ipairs(rules.hide or {}) do hide = hide or k == kind end
  for _, k in ipairs(rules.keep or {}) do keep = keep or k == part end
  return hide and not keep
end

-- A panel part's own name and kind from its full name, or nil for anything not directly in this
-- panel. base: the panel's full path. Parts inside the panel's buttons (their own trees) are left alone.
function M.part_of(full_name, base)
  local kind, path = tostring(full_name):match('^(%S+)%s+(.*)$')
  if not path or path:sub(1, #base) ~= base then return nil end
  local part = path:sub(#base + 1):match('^%.WidgetTree_%d+%.([%w_]+)$')
  if not part then return nil end
  return part, kind
end

return M
