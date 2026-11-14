-- The admin panel's work: showing, closing and trimming the game's own cheat panel, and sending a
-- typed line where it belongs. Loaded by main.lua, which binds the key. Every name of the game's and
-- every message comes from config.lua. Returns { toggle, typed, config, say }.
local DIR = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('panel%.lua$', '')
local CFG = dofile(DIR .. 'config.lua')
local route = dofile(DIR .. 'route.lua')
local G = CFG.game

local function say(key, values)
  print(CFG.log.tag .. route.fill(CFG.log[key], values) .. '\n')
end
local function valid(o)
  local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
  return ok and v == true
end

local function call(what, fn)
  local err
  for _ = 1, CFG.tries do
    local ok, r = pcall(fn)
    if ok then return true, r end
    err = r
  end
  say('failed', { what = what, tries = CFG.tries, error = err })
  return false
end

-- A game function called through the function object itself: looking it up by name on the object
-- fails for functions of some base classes on this build.
local functions = {}
local function ucall(obj, path, ...)
  local fn = functions[path] or StaticFindObject(path)
  if not valid(fn) then say('missing', { what = path }); return false end
  functions[path] = fn
  local args = { ... }
  return call(path, function() return obj:CallFunction(fn, table.unpack(args)) end)
end

-- Every live object of a class: not the class's own template.
local function live(class)
  local out = {}
  for _, o in ipairs(FindAllOf(class) or {}) do
    if valid(o) and not o:GetFullName():find(G.template_prefix, 1, true) then out[#out + 1] = o end
  end
  return out
end

local panel, shown, trimmed, hooked, commands, items, hint
local open_rows  -- defined with the search, used by the typed line before it

local function input_mode(pc, widget, ui)
  local lib = StaticFindObject(G.widgets)
  if ui then call(G.widgets, function() lib:SetInputMode_GameAndUIEx(pc, widget, 0, false, false) end)
  else call(G.widgets, function() lib:SetInputMode_GameOnly(pc, false) end) end
  pcall(function() pc.bShowMouseCursor = ui end)
end

-- The one panel: one left by an earlier load of this script is taken over, else the game makes it.
local function make_panel(pc)
  if valid(panel) then return panel end
  local w = live(G.panel_class)[1]
  if not w then
    local cls = StaticFindObject(G.panel)
    if not valid(cls) then say('missing', { what = G.panel }); return nil end
    local lib = StaticFindObject(G.widgets)
    local made
    made, w = call(G.panel, function() return lib:Create(pc, cls, pc) end)
    if not made or not valid(w) then say('not_made'); return nil end
    call(G.panel, function() w:AddToViewport(G.layer) end)
  end
  ucall(w, G.deactivate)
  ucall(w, G.set_visibility, G.hidden)
  panel, shown, trimmed = w, false, false
  return w
end

-- The game lays its panel out across the middle of the screen. The block that holds everything is
-- given a place of its own from config.lua: a share of the screen's width, standing on a bottom line.
local function dock(block)
  local slot
  pcall(function() slot = block.Slot end)
  if not valid(slot) then return end
  local at = CFG.layout
  ucall(slot, G.set_anchors, { Minimum = { X = at.left, Y = at.bottom }, Maximum = { X = at.right, Y = at.bottom } })
  ucall(slot, G.set_alignment, { X = 0.0, Y = 1.0 })
  ucall(slot, G.set_auto_size, true)
  ucall(slot, G.set_offsets,
    { Left = at.margin.left, Top = -at.margin.bottom, Right = at.margin.right, Bottom = 0.0 })
end

-- The panel's own widgets, each handed to visit with its name and kind: from the root down through
-- the containers, a few dozen lookups. (Looking through every object the game has loaded instead
-- stalled the game for a moment on the first press.) Buttons are not containers, so what is inside
-- them is left alone.
local function each_part(w, visit)
  local container = StaticFindObject(G.container)
  local function walk(widget)
    visit(widget, widget:GetFName():ToString(), widget:GetClass():GetFName():ToString())
    if not widget:IsA(container) then return end
    local ok, count = ucall(widget, G.child_count)
    for i = 0, (ok and count or 0) - 1 do
      local got, child = ucall(widget, G.child_at, i)
      if got and valid(child) then walk(child) end
    end
  end
  local root
  pcall(function() root = w[G.tree][G.root] end)
  if valid(root) and valid(container) then walk(root) end
end

local function trim(w)
  local parts, block = {}, nil
  each_part(w, function(widget, part, kind)
    if route.hidden(kind, part, CFG.panel) then parts[#parts + 1] = widget end
    if part == CFG.layout.part then block = widget end
    if part == CFG.hint.part then hint = widget end
  end)
  for _, o in ipairs(parts) do ucall(o, G.set_visibility, G.hidden) end
  if valid(block) then dock(block) end
  if valid(hint) then ucall(hint, G.set_visibility, G.shown) end
  trimmed = true
end

local function say_hint(text)
  if valid(hint) then ucall(hint, G.set_text, FText(text)) end
end

-- The game's own command names, from this player's cheat manager class and the classes under it.
local function game_commands(pc)
  if commands then return commands end
  local out, n = {}, 0
  pcall(function()
    local cls = pc.CheatManager:GetClass()
    while valid(cls) and cls:GetFName():ToString() ~= G.last_class do
      cls:ForEachFunction(function(fn) out[fn:GetFName():ToString():lower()] = true; n = n + 1 end)
      cls = cls:GetSuperStruct()
    end
  end)
  if n == 0 then return nil end
  commands = out
  return out
end

-- A line typed in the panel: the game's own commands are left to the game; the rest goes to the server.
local function typed(line)
  local pc = live(G.controller)[1]
  if not pc or #open_rows() > 0 then return nil end  -- with a list open the line is its search
  local where, text = route.route(line, game_commands(pc), CFG.word)
  -- Sent once, never retried: a call that failed after it left would run the line twice.
  if where == route.CONSOLE and not pcall(function() pc:ServerCheat(text) end) then
    say('failed', { what = G.typed_line, tries = 1, error = text })
  end
  return where, text
end

local function hook_typed_lines()
  if hooked or not valid(StaticFindObject(G.typed_line)) then return end
  hooked = pcall(RegisterHook, G.typed_line, function(_, Cmd)
    local ok, err = pcall(function() typed(Cmd:get():ToString()) end)
    if not ok then say('error', { error = err }) end
  end)
end

-- What the game's data says about each item a list row can stand for: its display name and whether
-- the game calls it published. Read once.
local function item_facts()
  if items then return items end
  items = {}
  for _, asset in ipairs(live(G.item_class)) do
    local id, label = asset:GetFName():ToString(), ''
    pcall(function() label = asset[G.item_label]:ToString() end)
    local ok, published = ucall(asset, G.is_published)
    items[id] = { label = label, published = not ok or published ~= false,
      category = asset:GetFullName():match(CFG.search.category) or '' }
  end
  return items
end

-- The rows of the game's open pick lists.
function open_rows()
  local found = {}
  for _, class in ipairs(CFG.close.lists) do
    for _, list in ipairs(live(class)) do
      local ok, open = ucall(list, G.is_activated)
      local rows, count
      if ok and open then pcall(function() rows = list[G.list_rows] end) end
      if valid(rows) then _, count = ucall(rows, G.child_count) end
      if count then found[#found + 1] = { rows = rows, count = count, key = list:GetAddress() } end
    end
  end
  return found
end

-- A list's rows, read from the game once per list and kept while its row count stays the same:
-- each row's object, what it is searched by, whether its item is published, and whether it shows.
local known = {}
local function rows_of(list)
  local kept = known[list.key]
  if kept and kept.count == list.count then return kept end
  kept = { count = list.count }
  local facts = item_facts()
  for i = 0, list.count - 1 do
    local got, row = ucall(list.rows, G.child_at, i)
    if not (got and valid(row)) then return {} end  -- not all there yet: read again next time
    local id = ''
    pcall(function() id = row[G.row_item]:ToString() end)
    local fact = facts[id] or { label = '', published = true, category = '' }
    kept[#kept + 1] = { row = row, published = fact.published, shows = true,  -- a row starts out showing
      text = route.search_text(id, fact.label .. ' ' .. fact.category, CFG.search.strip) }
  end
  known = { [list.key] = kept }  -- only the open list is kept
  return kept
end

-- The search: a row of an open list shows only if it has every typed word in its name, its data
-- name or its category and, unless the settings say otherwise, the game calls its item published.
-- Rows are the game's own; they are only shown or hidden, and only a row whose state changes is
-- touched. Returns how many rows show, of how many, and whether every change went through.
local function filter(query, lists)
  local showing, all, done = 0, 0, true
  for _, list in ipairs(lists or open_rows()) do
    for _, r in ipairs(rows_of(list)) do
      local show = (r.published or CFG.search.show_unpublished) and route.matches(r.text, query)
      if show ~= r.shows then
        if valid(r.row) and ucall(r.row, G.set_visibility, show and G.row_shown or G.hidden) then r.shows = show
        else done = false end
      end
      all, showing = all + 1, showing + (show and 1 or 0)
    end
  end
  return showing, all, done
end

-- While the panel shows, the open lists are looked at every search.every_ms. A list is left alone
-- until its rows have held still for search.settle_ms: the game builds a list's rows over several
-- frames, and reading one too early crashed the game. What is typed while a list is open (key, below)
-- is kept in query, cleared whenever the set of open lists changes, and the rows are gone through
-- again only when query or the lists change. One loop at a time: a newer load of this script ends
-- the older one's.
_G.MoonpoolConsoleLoads = (_G.MoonpoolConsoleLoads or 0) + 1
local load, following, last, seen, still, query = _G.MoonpoolConsoleLoads, false, nil, nil, 0, ''
local function apply(lists, rows)
  if still < CFG.search.settle_ms then return end
  local now = query .. '|' .. rows
  if now == last then return end
  local went, _, _, done = pcall(filter, query, lists)
  if went and done then last = now end
end
local function lists_now()
  local lists, rows = open_rows(), ''
  for _, list in ipairs(lists) do rows = rows .. list.key .. ':' .. list.count .. ' ' end
  return lists, rows
end
local function follow_lists()
  if following or not CFG.search.live then return end
  following = true
  LoopAsync(CFG.search.every_ms, function()
    if not shown or load ~= _G.MoonpoolConsoleLoads then following = false; return true end
    ExecuteInGameThread(function()
      if not (shown and valid(panel)) then return end
      local lists, rows = lists_now()
      if rows ~= seen then
        still, query = 0, ''
        say_hint(rows == '' and CFG.hint.text or route.fill(CFG.hint.filtering, { query = '' }))
      else
        still = still + CFG.search.every_ms
      end
      seen = rows
      apply(lists, rows)
    end)
    return false
  end)
end

-- A typing key while the panel shows a list: char is what it types, nil takes one back. With no list
-- open it does nothing, and the key keeps its meaning for whatever has the keyboard.
local function key(char)
  if not (shown and seen and seen ~= '') then return end
  query = char and (query .. char) or query:sub(1, -2)
  say_hint(route.fill(CFG.hint.filtering, { query = query }))
  apply(lists_now())
end

-- Closing the panel closes what it opened. The game keeps its pick lists in a stack: closing the top
-- one brings the one under it back a moment later, so the open one is closed, then the next after
-- close.wait_ms, until none is open (at most close.most times).
local function close_lists(left)
  local closed = false
  for _, class in ipairs(CFG.close.lists) do
    for _, list in ipairs(live(class)) do
      local ok, open = ucall(list, G.is_activated)
      if ok and open then closed = ucall(list, G.deactivate) or closed end
    end
  end
  if closed and left > 1 then
    ExecuteWithDelay(CFG.close.wait_ms, function()
      ExecuteInGameThread(function() pcall(close_lists, left - 1) end)
    end)
  end
end

-- The game's diagnostic windows close by its own commands.
local function close_opened(pc)
  close_lists(CFG.close.most)
  local run = StaticFindObject(G.system)
  for _, line in ipairs(CFG.close.commands) do
    call(line, function() run:ExecuteConsoleCommand(pc, line, pc) end)
  end
end

-- A second press while the first is still being carried out is ignored: opening and closing the
-- panel in the same instant, on a panel only just made, crashed the game.
local busy = false
local function toggle()
  if busy then return end
  busy = true
  ExecuteWithDelay(CFG.toggle_gap_ms, function() busy = false end)
  local pc = live(G.controller)[1]
  local w = pc and make_panel(pc)
  if not w then return end
  local want = not shown
  if not ucall(w, G.set_visibility, want and G.shown or G.hidden) then return end
  shown = want
  ucall(w, want and G.activate or G.deactivate)
  input_mode(pc, w, want)
  if want then
    if not trimmed then trim(w) end
    hook_typed_lines()
    say_hint(CFG.hint.text)
    follow_lists()
  else
    close_opened(pc)
  end
end

-- One step back: open lists close first; with none open, the panel closes. Nothing happens while
-- the panel is not showing, so the key keeps its own meaning in the game.
local function back()
  if not shown then return end
  if #open_rows() > 0 then close_lists(CFG.close.most) else toggle() end
end

return { toggle = toggle, back = back, key = key, typed = typed, filter = filter, config = CFG, say = say }
