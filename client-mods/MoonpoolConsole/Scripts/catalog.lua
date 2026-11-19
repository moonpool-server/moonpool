-- The palette's entries and its search, with no game calls: one list of the game's items, the game's
-- commands, the server's commands and a player's own entries, each with the lines its actions send.
local M = {}

local function lower(s) return tostring(s or ''):lower() end

-- An entry: { key, name, detail, kind, actions = { { label, line = template } }, args = { {name, default} } }.
-- A template's {names} are filled from the entry (id) and its args when an action runs.

-- The game's items: facts maps an item's data id to { label, category, published, equippable }.
-- An action with ids (from the game's own list, list_actions) is offered only for the items it holds.
-- Same-named items are told apart by their data id in detail.
function M.items(facts, actions, show_unpublished, hidden_categories)
  local out = {}
  -- An item's second line is its category in the game's data; the data name is added only where two
  -- items share a display name, so they can be told apart.
  local named = {}
  for _, f in pairs(facts or {}) do named[f.label] = (named[f.label] or 0) + 1 end
  for id, f in pairs(facts or {}) do
    local hidden = false
    for _, c in ipairs(hidden_categories or {}) do hidden = hidden or f.category == c end
    if (f.published or show_unpublished) and f.label ~= '' and not (hidden and not show_unpublished) then
      local acts = {}
      for _, a in ipairs(actions or {}) do
        local held = not a.ids or a.ids[id]
        if (not a.equippable or f.equippable) and held then
          acts[#acts + 1] = { label = a.label, line = a.line }
        end
      end
      out[#out + 1] = { key = 'item:' .. id, id = id, name = f.label, kind = 'item',
        detail = named[f.label] > 1 and ((f.category ~= '' and f.category .. ' · ' or '') .. id)
          or (f.category ~= '' and f.category or id), actions = acts,
        args = { { name = 'count', default = '1' } } }
    end
  end
  return out
end

-- A game list's own command as an action line: its {0} is the item ({id}) and a number at its end the
-- count ({count}): "Item {0} 1" -> "Item {id} {count}". Nil when the command names no item.
function M.list_line(command)
  command = tostring(command or '')
  if not command:find('{0}', 1, true) then return nil end
  local line = command:gsub('{0}', '{id}')
  return (line:gsub('%s%d+%s*$', ' {count}'))
end

-- Item actions from the game's own lists ({ label, command, ids = { [id] = true } }): an item gets an
-- action only if that list holds it, with the list's own command. Lists that could not be read
-- (no ids) are left out; with none read, nil, and the caller keeps its own actions.
function M.list_actions(lists)
  local out = {}
  for _, l in ipairs(lists or {}) do
    local line = M.list_line(l.command)
    if line and next(l.ids or {}) then out[#out + 1] = { label = l.label, line = line, ids = l.ids } end
  end
  return #out > 0 and out or nil
end

-- The game's own commands (lowercase name -> name), sent as typed. params maps a name to its
-- parameters, { { name, kind } }, for the signature shown under the list.
function M.game_commands(names, label, params)
  local out = {}
  for _, name in pairs(names or {}) do
    out[#out + 1] = { key = 'game:' .. name, name = name, kind = 'command', detail = label or '',
      actions = { { label = 'Run', line = name } }, args = {}, signature = M.signature(name, (params or {})[name]) }
  end
  return out
end

-- How a command is written: its name, then <name: kind> for each parameter, [name = default] for
-- one that may be left out.
function M.signature(name, params)
  local parts = { name }
  for _, p in ipairs(params or {}) do
    if p.default ~= nil then parts[#parts + 1] = '[' .. p.name .. ' = ' .. tostring(p.default) .. ']'
    elseif p.kind then parts[#parts + 1] = '<' .. p.name .. ': ' .. p.kind .. '>'
    else parts[#parts + 1] = '<' .. p.name .. '>' end
  end
  return table.concat(parts, '  ')
end

-- The server's commands, from host-commands.lua (written from the server's console.json when the mod
-- is published): each command's first alias with its arguments, led by the server's word. A help
-- line that begins a part (between ' · ') with the command's word is its detail.
local function help_for(word, lines)
  for _, line in ipairs(lines or {}) do
    for part in (tostring(line) .. ' · '):gmatch('(.-) · ') do
      if lower(part):match('^%s*(%S+)') == word then return line end
    end
  end
  return ''
end
function M.host_commands(host)
  local out = {}
  if type(host) ~= 'table' or type(host.commands) ~= 'table' then return out end
  local word = tostring(host.word or 'mp')
  local function add(name, aliases, args)
    local say = tostring((aliases or {})[1] or name)
    local template, list = { word, say }, {}
    for _, a in ipairs(args or {}) do
      template[#template + 1] = '{' .. a.name .. '}'
      list[#list + 1] = { name = a.name, default = a.default, kind = a.kind }
    end
    out[#out + 1] = { key = 'host:' .. name, name = say, kind = 'server', detail = help_for(lower(say), host.help),
      actions = { { label = 'Run', line = table.concat(template, ' ') } }, args = list,
      signature = M.signature(word .. ' ' .. say, list) }
  end
  for name, c in pairs(host.commands) do add(name, c.aliases, c.args) end
  for name, aliases in pairs(host.verbs or {}) do add(name, aliases, {}) end
  return out
end

-- A player's own rows, the same shape as the built-in ones: { name, detail, line } for one action, or
-- actions = { { label, line } } for several; args = { { name, default } } fills {name} in the lines;
-- local_run = true runs the lines in the game's console on this PC instead of sending them. Rows that
-- are not that shape are skipped.
function M.own(list)
  local out = {}
  for _, e in ipairs(type(list) == 'table' and (list[1] and list or { list }) or {}) do
    local acts = {}
    if type(e) == 'table' and type(e.actions) == 'table' then
      for _, a in ipairs(e.actions) do
        if type(a) == 'table' and type(a.label) == 'string' and type(a.line) == 'string' then
          acts[#acts + 1] = { label = a.label, line = a.line, local_run = e.local_run == true }
        end
      end
    elseif type(e) == 'table' and type(e.line) == 'string' then
      acts[1] = { label = 'Run', line = e.line, local_run = e.local_run == true }
    end
    if type(e) == 'table' and type(e.name) == 'string' and #acts > 0 then
      local args = {}
      for _, a in ipairs(type(e.args) == 'table' and e.args or {}) do
        if type(a) == 'table' and type(a.name) == 'string' then
          args[#args + 1] = { name = a.name, default = a.default }
        end
      end
      out[#out + 1] = { key = 'own:' .. e.name, name = e.name, kind = 'own', detail = tostring(e.detail or ''),
        actions = acts, args = args }
    end
  end
  return out
end

-- The game's macros, each run on this PC by the game's own macro command, which sends its lines to the
-- server one by one: a list of { name, id, detail } (from the game's own Macro list, or the settings)
-- and the line that runs one, {id} for its name.
function M.macros(list, line)
  local out = {}
  for _, m in ipairs(list or {}) do
    out[#out + 1] = { key = 'macro:' .. (m.id or m.name), name = m.name, kind = 'macro',
      detail = tostring(m.detail or ''), local_run = true,
      actions = { { label = 'Run', line = (line or 'RunMacro {id}'), local_run = true } },
      id = m.id or m.name, args = {} }
  end
  return out
end

-- The rows a search looks through: recent lines only on their own tab, or on All while nothing is
-- typed, so old lines don't crowd out what a search is for.
function M.searchable(entries, kind, query)
  if kind == 'recent' or tostring(query or ''):match('^%s*$') then return entries end
  local out = {}
  for _, e in ipairs(entries) do if e.kind ~= 'recent' then out[#out + 1] = e end end
  return out
end

-- The line that runs an action for someone else: the action's own line, run by the server's console
-- as that player (or every player), so Spawn spawns at each one's own place.
-- template: with {word}, {who} (a name's first word, or the server's word for everyone) and {line}.
function M.for_others(template, word, who, line)
  local first = tostring(who or ''):match('^(%S+)') or ''
  return (tostring(template):gsub('{(%w+)}', function(k)
    return ({ word = word, who = first, line = line })[k] or ''
  end))
end

-- Whether Enter sends line now, for a line that waits for a second Enter: it goes when waiting holds
-- the same line from at most window seconds before. Returns go, and what waits after this Enter.
function M.confirm(waiting, line, now, window)
  if waiting and waiting.line == line and now - waiting.at <= window then return true, nil end
  return false, { line = line, at = now }
end

-- The line that undoes line, from rules: a list of { pattern, undo } where undo may use %1.. for the
-- pattern's captures and {word} for the server's word. Nil when no rule knows one.
function M.opposite(line, rules, word)
  line = tostring(line or '')
  for _, r in ipairs(rules or {}) do
    local caps = { line:match(r[1]) }
    if caps[1] ~= nil then
      local undo = r[2]:gsub('%%(%d)', function(n) return caps[tonumber(n)] or '' end)
      return (undo:gsub('{word}', word or 'mp'))
    end
  end
  return nil
end

-- How well an entry answers a query: nil when one of the words is missing from its name and detail.
-- Lower is better: the name starting with the query, then a word of the name starting with it, then
-- the words anywhere.
function M.score(entry, query)
  local q = lower(query):match('^%s*(.-)%s*$')
  if q == '' then return 3 end
  local name, text = lower(entry.name), lower(entry.name) .. ' ' .. lower(entry.detail)
  for w in q:gmatch('%S+') do
    if not text:find(w, 1, true) then return nil end
  end
  if name:sub(1, #q) == q then return 0 end
  if name:find('%f[%w]' .. q:gsub('%p', '%%%0')) then return 1 end
  return 2
end

-- The entries that answer query, best first (then shorter, then A to Z), at most limit. kind limits
-- them to one kind. pinned names come first while nothing is typed.
function M.search(entries, query, limit, kind, pinned)
  local found = {}
  for _, e in ipairs(entries or {}) do
    if not kind or e.kind == kind then
      local s = M.score(e, query)
      if s then
        if s == 3 and pinned and pinned[e.key] then s = -1 end
        found[#found + 1] = { e = e, s = s }
      end
    end
  end
  table.sort(found, function(a, b)
    if a.s ~= b.s then return a.s < b.s end
    if #a.e.name ~= #b.e.name then return #a.e.name < #b.e.name end
    return a.e.name < b.e.name
  end)
  local out = {}
  for i = 1, math.min(#found, limit or #found) do out[i] = found[i].e end
  return out, #found
end

-- The line an action sends: its template with {id} and the args filled in; an arg not given takes
-- its default, and nil comes back with the arg's name when one has neither.
function M.line(entry, action, values)
  values = values or {}
  local missing
  local line = tostring(action.line):gsub('{(%w+)}', function(k)
    if k == 'id' then return entry.id or entry.name end
    local v = values[k]
    if v == nil or v == '' then
      for _, a in ipairs(entry.args or {}) do if a.name == k then v = a.default end end
    end
    if v == nil or v == '' then missing = missing or k; return '' end
    return tostring(v)
  end)
  if missing then return nil, missing end
  return (line:gsub('%s+$', ''))
end

-- The line to edit before sending: the whole line when every argument has a value, otherwise the
-- line up to the first argument nobody gave, so its value is typed next.
function M.draft(entry, action, values)
  local line, missing = M.line(entry, action, values)
  if line then return line end
  local head = tostring(action.line):match('^(.-){' .. missing .. '}') or ''
  return (M.line(entry, { line = head }, values) or head) .. ' '
end

return M
