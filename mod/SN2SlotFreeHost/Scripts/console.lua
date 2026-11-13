-- The in-game admin console: one line in, reply lines and console lines to run out. Pure Lua, no
-- game calls: the caller passes the live data (players, items, places, commands, tags) and runs
-- what comes back. Every word and reply comes from the catalog (console.json); this file only
-- parses, matches and plans. Admin rights are checked by the caller, before this runs.
local fzy = require('fzy_lua')
local M = {}

local function lower(s) return (tostring(s or '')):lower() end

-- Words, with "double quotes" keeping spaces; each word remembers whether it was quoted.
function M.tokens(text)
  local out, i, s = {}, 1, tostring(text or '')
  while i <= #s do
    local c = s:sub(i, i)
    if c:match('%s') then
      i = i + 1
    elseif c == '"' then
      local j = s:find('"', i + 1, true) or (#s + 1)
      out[#out + 1] = { text = s:sub(i + 1, j - 1), quoted = true }
      i = j + 1
    else
      local j = s:find('[%s"]', i) or (#s + 1)
      out[#out + 1] = { text = s:sub(i, j - 1), quoted = false }
      i = j
    end
  end
  return out
end

-- An alias -> name map from {name = {aliases...}} or {name = {aliases = {...}}}.
local function aliases(t)
  local map = {}
  for name, v in pairs(t or {}) do
    map[lower(name)] = name
    for _, a in ipairs(v.aliases or v) do map[lower(a)] = name end
  end
  return map
end

function M.new(catalog)
  return { cat = catalog, last = {}, pending = {},
    verbs = aliases(catalog.verbs), commands = aliases(catalog.commands), kinds = aliases(catalog.kinds),
    targets = aliases(catalog.targets), repeats = aliases({ ['.'] = catalog['repeat'] or {} }) }
end

-- A reply line from the catalog's template; a missing key shows as itself, and a test catches it.
function M.msg(st, key, vars)
  local t = st.cat.messages and st.cat.messages[key]
  if not t then return '?' .. key end
  return (t:gsub('{(%w+)}', function(k) return vars and vars[k] ~= nil and tostring(vars[k]) or '' end))
end

-- Entries {id, name} of one kind that match the query, best first: an exact id or name wins alone,
-- then a unique prefix of the name, then fzy's ranking.
function M.match(entries, query)
  local q = lower(query)
  local exact, prefix, fuzzy = {}, {}, {}
  for _, e in ipairs(entries or {}) do
    local n, id = lower(e.name), lower(e.id)
    if n == q or id == q then exact[#exact + 1] = e
    elseif n:sub(1, #q) == q then prefix[#prefix + 1] = e
    elseif fzy.has_match(q, n) or fzy.has_match(q, id) then
      local sc = math.max(fzy.has_match(q, n) and fzy.score(q, n) or -math.huge,
        fzy.has_match(q, id) and fzy.score(q, id) or -math.huge)
      fuzzy[#fuzzy + 1] = { e = e, score = sc }
    end
  end
  if #exact > 0 then return exact end
  if #prefix > 0 then return prefix end
  table.sort(fuzzy, function(a, b) return a.score > b.score end)
  local out = {}
  for _, f in ipairs(fuzzy) do out[#out + 1] = f.e end
  return out
end

local function rows(st, list, key, extra)
  local lines, max = {}, st.cat.max_lines or 12
  for i, e in ipairs(list) do
    if i > max then
      lines[#lines + 1] = M.msg(st, 'more', { count = #list - max })
      break
    end
    local vars = { name = e.name, id = e.id, eos = e.eos, ping = e.ping, tag = e.name }
    for k, v in pairs(extra or {}) do vars[k] = v end
    lines[#lines + 1] = M.msg(st, key, vars)
  end
  return lines
end

local function names(list, max)
  local out = {}
  for i, e in ipairs(list) do
    if i > max then break end
    out[#out + 1] = e.name
  end
  return table.concat(out, ', ')
end

-- Several things match: take the first when the catalog says so, else ask, numbered, and remember
-- the line so a bare number answers it.
local function choose(st, req, found, query)
  if st.cat.on_ambiguous == 'first' then return found[1].id end
  local list, max = {}, math.min(#found, st.cat.max_choices or 6)
  for i = 1, max do list[#list + 1] = i .. ' ' .. found[i].name end
  st.pending[req.sender.key or req.sender.name] = { text = req.text, query = lower(query), found = found, max = max }
  return nil, M.msg(st, 'choose', { query = query, choices = table.concat(list, '  ') })
end

-- One value of a kind for a typed query: the id, or nil and the reply that says why.
local function resolve(st, game, kind, query, req)
  local forced = req.forced and req.forced[lower(query)]
  if forced then return forced end
  local found = M.match(game.list(kind), query)
  if #found == 1 then return found[1].id end
  if #found == 0 then return nil, M.msg(st, 'no_match', { kind = kind, query = query }) end
  return choose(st, req, found, query)
end

local function denied(st, line)
  local word = lower(line:match('^%s*(%S+)') or '')
  for _, pat in ipairs(st.cat.deny or {}) do
    local p = lower(pat)
    if (p:sub(-1) == '*' and word:sub(1, #p - 1) == p:sub(1, -2)) or word == p then return word end
  end
end

-- Who a line runs as: a list of player names, or nil and a reply.
local function targets(st, game, who, sender)
  local word = st.targets[lower(who)]
  local players = game.list('players')
  if word == 'me' then return { sender.name } end
  if word == 'host' then return { game.host } end
  if word == 'all' then
    local all = {}
    for _, p in ipairs(players) do all[#all + 1] = p.name end
    return all
  end
  local found = M.match(players, who)
  if #found == 1 then return { found[1].name } end
  if #found == 0 then return nil, M.msg(st, 'no_player', { query = who }) end
  return nil, M.msg(st, 'ambiguous', { query = who, matches = names(found, 8) })
end

local function join(tokens, from)
  local out = {}
  for i = from, #tokens do out[#out + 1] = tokens[i].text end
  return table.concat(out, ' ')
end

-- req: {sender = {name, key}, text}; game: {list = function(kind) -> {{id, name, ...}}, host = name}.
-- Returns {lines = reply lines, runs = {{player, line}}}.
function M.handle(st, req, game)
  local tokens = M.tokens(req.text)
  local key = req.sender.key or req.sender.name
  local out = { lines = {}, runs = {} }
  local function say(t) for _, l in ipairs(type(t) == 'table' and t or { t }) do out.lines[#out.lines + 1] = l end end

  local picked = tonumber(tostring(req.text or ''):match('^%s*(%d+)%s*$'))
  if picked and st.pending[key] then
    local p = st.pending[key]
    st.pending[key] = nil
    if picked < 1 or picked > p.max then say(M.msg(st, 'no_choice', { count = p.max })); return out end
    return M.handle(st, { sender = req.sender, text = p.text, forced = { [p.query] = p.found[picked].id } }, game)
  end
  if not req.forced then st.pending[key] = nil end

  if tokens[1] and st.repeats[lower(tokens[1].text)] then
    if not st.last[key] then say(M.msg(st, 'no_last')); return out end
    tokens = st.last[key]
  else
    st.last[key] = tokens
  end

  local who = { req.sender.name }
  local mark = st.cat.target_mark or '@'
  if tokens[1] and tokens[1].text:sub(1, #mark) == mark then
    local t, why = targets(st, game, tokens[1].text:sub(#mark + 1), req.sender)
    if not t then say(why); return out end
    who = t
    table.remove(tokens, 1)
  end
  if #tokens == 0 then return M.handle(st, { sender = req.sender, text = 'help' }, game) end

  local first = lower(tokens[1].text)
  if not st.verbs[first] and not st.commands[first] and #first >= 3 then
    local near = {}
    for alias in pairs(st.verbs) do near[#near + 1] = { id = alias, name = alias } end
    for alias in pairs(st.commands) do near[#near + 1] = { id = alias, name = alias } end
    local hits = M.match(near, first)
    local real = false  -- a word the game itself knows is never rewritten
    for _, c in ipairs(game.list('commands') or {}) do real = real or lower(c.name) == first end
    if #hits == 1 and not real then first = hits[1].id end
  end
  local verb = st.verbs[first]
  if verb == 'help' then
    local short = {}
    for name, c in pairs(st.cat.commands or {}) do short[#short + 1] = (c.aliases or {})[1] or name end
    table.sort(short)
    say(M.msg(st, 'help', { shortcuts = table.concat(short, ' ') }))
    return out
  end
  if verb == 'who' then
    local list = game.list('players')
    say(#list > 0 and rows(st, list, 'who_row') or M.msg(st, 'who_none'))
    return out
  end
  if verb == 'cheats' then
    local tags = game.list('tags')
    if tags == nil then say(M.msg(st, 'cheats_unknown')); return out end
    local on, prefix = {}, lower(st.cat.cheat_prefix or '')
    for _, t in ipairs(tags) do if lower(t.name):sub(1, #prefix) == prefix then on[#on + 1] = t end end
    say(#on > 0 and rows(st, on, 'cheats_row') or M.msg(st, 'cheats_none'))
    return out
  end
  if verb == 'ls' then
    local kind = tokens[2] and st.kinds[lower(tokens[2].text)]
    if not kind then
      local all = {}
      for name in pairs(st.cat.kinds or {}) do all[#all + 1] = name end
      table.sort(all)
      say(M.msg(st, 'ls_kinds', { kinds = table.concat(all, ' ') }))
      return out
    end
    local query = join(tokens, 3)
    local list = query == '' and (game.list(kind) or {}) or M.match(game.list(kind), query)
    say(#list > 0 and rows(st, list, 'ls_row') or M.msg(st, 'ls_none', { kind = kind, query = query }))
    return out
  end

  local query = join(tokens, verb == 'find' and 2 or 1)
  local command = st.commands[first]
  -- A lone word that is no verb, shortcut or game command means find.
  if not verb and not command and #tokens == 1 and not tokens[1].quoted then
    local cmds = game.list('commands') or {}
    if #cmds > 0 and #M.match(cmds, first) == 0 then verb = 'find' end
  end
  if verb == 'find' then
    local hits = {}
    for kind in pairs(st.cat.kinds or {}) do
      for _, e in ipairs(M.match(game.list(kind), query)) do
        hits[#hits + 1] = { name = e.name, id = e.id, kind = kind }
      end
    end
    table.sort(hits, function(a, b) return a.kind < b.kind or (a.kind == b.kind and a.name < b.name) end)
    local lines = {}
    for i, h in ipairs(hits) do
      if i > (st.cat.max_lines or 12) then
        lines[#lines + 1] = M.msg(st, 'more', { count = #hits - (st.cat.max_lines or 12) }); break
      end
      lines[#lines + 1] = M.msg(st, 'find_row', h)
    end
    say(#hits > 0 and lines or M.msg(st, 'find_none', { query = query }))
    return out
  end

  -- What to run: a shortcut's lines with its arguments resolved, or the typed line itself with any
  -- "quoted name" resolved to the game's id.
  local lines = {}
  if command then
    local c = st.cat.commands[command]
    local values, words, numbers = {}, {}, {}
    for i = 2, #tokens do  -- the name's words and the number can come in any order, quotes or not
      local t = tokens[i]
      if not t.quoted and t.text:match('^%-?%d+%.?%d*$') then numbers[#numbers + 1] = t.text
      else words[#words + 1] = t.text end
    end
    local name = table.concat(words, ' ')
    for _, a in ipairs(c.args or {}) do
      local typed
      if a.kind then
        typed, name = name ~= '' and name or nil, ''
      else
        typed = table.remove(numbers, 1)
      end
      if not typed and a.default == nil then
        say(M.msg(st, 'missing_arg', { command = command, arg = a.name }))
        return out
      end
      if typed and a.kind then
        local id, why = resolve(st, game, a.kind, typed, req)
        if not id then say(why); return out end
        values[a.name] = id
      else
        values[a.name] = typed or a.default
      end
    end
    for _, l in ipairs(c.lines or {}) do
      lines[#lines + 1] = (l:gsub('{(%w+)}', function(k) return values[k] or '' end))
    end
  else
    local words = {}
    for _, t in ipairs(tokens) do
      if t.quoted then
        local id = req.forced and req.forced[lower(t.text)]
        for _, kind in ipairs(not id and st.cat.resolve_kinds or {}) do
          local found = M.match(game.list(kind), t.text)
          if #found == 1 then id = found[1].id; break end
          if #found > 1 then
            local why
            id, why = choose(st, req, found, t.text)
            if not id then say(why); return out end
            break
          end
        end
        if not id then
          say(M.msg(st, 'no_match', { kind = table.concat(st.cat.resolve_kinds or {}, '/'), query = t.text }))
          return out
        end
        words[#words + 1] = id
      else
        words[#words + 1] = t.text
      end
    end
    lines[1] = table.concat(words, ' ')
  end

  for _, l in ipairs(lines) do
    local word = denied(st, l)
    if word then say(M.msg(st, 'denied', { word = word })); return out end
  end
  for _, p in ipairs(who) do
    for _, l in ipairs(lines) do out.runs[#out.runs + 1] = { player = p, line = l } end
  end
  say(M.msg(st, 'ran', { count = #out.runs, players = table.concat(who, ', '), lines = table.concat(lines, ' | ') }))
  return out
end

return M
