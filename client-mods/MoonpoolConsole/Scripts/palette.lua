-- The admin palette: one search over the game's items, the game's commands, the server's commands,
-- the lines run before and a player's own rows, with the actions each row offers. Built inside the
-- game's own cheat panel, whose parts are hidden, so the game's menu handling still applies. Loaded
-- by main.lua, which binds the keys. Every name of the game's and every message is in config.lua.
local DIR = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('palette%.lua$', '')
local CFG = dofile(DIR .. 'config.lua')
local route = dofile(DIR .. 'route.lua')
local catalog = dofile(DIR .. 'catalog.lua')
local HOME = os.getenv('LOCALAPPDATA') or ''
-- A player's file, run with no libraries (it can't open files or run programs), for the table it returns.
local function values(path)
  local f = loadfile(path, 't', {})
  if not f then return nil end
  local ok, t = pcall(f)
  if ok then return t end
  return nil, t
end
do
  local own, err = values(HOME .. CFG.own_settings)
  if own then route.merge(CFG, own)
  elseif err then print(CFG.log.tag .. 'own settings not read: ' .. tostring(err) .. '\n') end
end
local G, C = CFG.game, CFG.colors

local function say(key, v) print(CFG.log.tag .. route.fill(CFG.log[key], v) .. '\n') end
local function valid(o)
  local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
  return ok and v == true
end

-- A game call, tried up to CFG.tries times. One that needed more than one try is logged once.
local retried = {}
local function call(what, fn)
  local err
  for n = 1, CFG.tries do
    local ok, r = pcall(fn)
    if ok then
      if n > 1 and not retried[what] then retried[what] = true; say('retried', { what = what, tries = n }) end
      return true, r
    end
    err = r
  end
  say('failed', { what = what, tries = CFG.tries, error = err })
  return false
end
-- A game function called through the function object itself: looked up by name it fails for
-- functions of some base classes on this build.
local functions = {}
local function ucall(obj, path, ...)
  local fn = functions[path] or StaticFindObject(path)
  if not valid(fn) then say('missing', { what = path }); return false end
  functions[path] = fn
  local args = { ... }
  return call(path, function() return obj:CallFunction(fn, table.unpack(args)) end)
end
local function live(class)
  local out = {}
  for _, o in ipairs(FindAllOf(class) or {}) do
    if valid(o) and not o:GetFullName():find(G.template_prefix, 1, true) then out[#out + 1] = o end
  end
  return out
end
local function ms_since(t) return math.floor((os.clock() - t) * 1000 + 0.5) end
local function trace(what, t) if CFG.trace then say('timing', { what = what, ms = ms_since(t) }) end end

-- ---- the rows ----------------------------------------------------------------------------------

local recent = {}
local recent_file = HOME .. CFG.history.file
pcall(function() for l in io.lines(recent_file) do recent[#recent + 1] = l end end)
local function remember(ran)
  recent = route.remember(recent, ran, CFG.history.keep)
  pcall(function()
    local f = assert(io.open(recent_file, 'w'))
    f:write(table.concat(recent, '\n'), '\n')
    f:close()
  end)
end

local host = values(DIR .. CFG.host_commands)
local WORD = (type(host) == 'table' and host.word) or CFG.word

-- The game's own command names (lowercase -> name), from this player's cheat manager classes, and
-- each one's parameters ({ name, kind }) for its signature.
local commands, params = nil, {}
local KINDS = { StrProperty = 'text', NameProperty = 'name', TextProperty = 'text', IntProperty = 'number',
  FloatProperty = 'number', DoubleProperty = 'number', BoolProperty = '0 or 1' }
local function game_commands(pc)
  if commands then return commands end
  local out, n = {}, 0
  pcall(function()
    local cls = pc.CheatManager:GetClass()
    while valid(cls) and cls:GetFName():ToString() ~= G.last_class do
      cls:ForEachFunction(function(fn)
        local name = fn:GetFName():ToString()
        out[name:lower()], n = name, n + 1
        local list = {}
        pcall(function() fn:ForEachProperty(function(p)
          local pname, pclass = p:GetFName():ToString(), p:GetClass():GetFName():ToString()
          if pname ~= 'ReturnValue' then list[#list + 1] = { name = pname, kind = KINDS[pclass] or pclass } end
        end) end)
        params[name] = list
      end)
      cls = cls:GetSuperStruct()
    end
  end)
  if n == 0 then return nil end
  commands = out
  return out
end

-- What the game's data says about each item: name, category, published (and not marked unfinished)
-- and equippable. Read once, at the first opening.
-- An item's category: the last part of its own category tag in the game's data (Item.Category.Tools ->
-- Tools), else the folder its data is in.
local function category_of(asset)
  local tag = ''
  pcall(function() tag = asset[G.item_category][G.tag_name]:ToString() end)
  local last = tag ~= 'None' and tag:match('([%w_]+)$') or nil
  return last or asset:GetFullName():match(CFG.items.category) or ''
end
local function item_facts()
  local facts = {}
  for _, asset in ipairs(live(G.item_class)) do
    local id, label = asset:GetFName():ToString(), ''
    pcall(function() label = asset[G.item_label]:ToString() end)
    local ok, published = ucall(asset, G.is_published)
    local finished = true
    for _, p in ipairs(CFG.items.unfinished or {}) do finished = finished and not label:find(p) end
    local eok, equippable = ucall(asset, G.is_equippable)
    facts[id] = { label = label, published = (not ok or published ~= false) and finished,
      equippable = eok and equippable == true,
      category = category_of(asset) }
  end
  return facts
end

local entries  -- every row but the recent ones, built at the first opening
local function own_rows()
  local file = HOME .. CFG.own_commands
  local t, err = values(file)
  if err then say('own_bad', { file = file, error = err }) end
  return catalog.own(t)
end
-- What each of the game's own cheat lists holds, read through the panel's own handlers: each is run as
-- a click on its button runs it, its list's view model is read (the command, the items' data names)
-- and the list is closed with the game's own command. A list that cannot be read is left out.
-- One of the game's own cheat lists, read through the panel's own handler: it is run as a click on
-- its button runs it, the list it fills is read (its command; each item's data name and title) and
-- closed the game's way (a list still active after that is deactivated and hidden, or it would stay
-- on screen behind the palette). The list read is the one the handler filled: a view model that was
-- not there before, or one whose command changed. Nil when it cannot be read.
local function read_game_list(pc, panel, def)
  local button
  pcall(function() button = panel[def.button] end)
  if not (def and valid(panel) and valid(button)) then return nil end
  local before = {}
  for _, vm in ipairs(live(G.list_model)) do
    local c = ''
    pcall(function() c = vm[G.list_command]:ToString() end)
    before[vm:GetAddress()] = c
  end
  local handler = route.fill(G.list_handler, def)
  if not pcall(function() panel[handler](panel, button) end) then return nil end
  local found
  for _, vm in ipairs(live(G.list_model)) do
    local c = ''
    pcall(function() c = vm[G.list_command]:ToString() end)
    if before[vm:GetAddress()] ~= c then
      found = { command = c, items = {} }
      pcall(function()
        local items = vm[G.list_items]
        for i = 1, items:GetArrayNum() do
          local id, title
          pcall(function() id = items[i][G.list_id]:ToString() end)
          pcall(function() title = items[i][G.list_title]:ToString() end)
          if id then found.items[#found.items + 1] = { id = id, title = title or id } end
        end
      end)
    end
  end
  if CFG.trace then
    say('key', { what = 'list ' .. def.button .. ': ' .. (found and (found.command .. ', ' .. #found.items .. ' items')
      or ('nothing new among ' .. #live(G.list_model) .. ' view models')) })
  end
  local system = StaticFindObject(G.system)
  pcall(function() system:ExecuteConsoleCommand(pc, G.hide_list, pc) end)
  for _, list in ipairs(live(G.list_widget)) do
    local ok, open = ucall(list, G.is_activated)
    if ok and open then ucall(list, G.deactivate) end
    ucall(list, G.set_visibility, G.collapsed)
  end
  return found
end
-- The item actions' lists: { label, command, ids } each.
local function game_lists(pc, panel)
  local out = {}
  for _, want in ipairs(CFG.list_actions) do
    local list = read_game_list(pc, panel, G.lists[want.list])
    local entry = { label = want.label, ids = {}, command = list and list.command }
    for _, it in ipairs(list and list.items or {}) do entry.ids[it.id] = true end
    out[#out + 1] = entry
  end
  return out
end
-- The game's macros, from its own Macro list: { name, id } each and the line that runs one.
local function game_macros(pc, panel)
  local list = read_game_list(pc, panel, G.lists.macro)
  if not (list and #list.items > 0) then return nil end
  local out = {}
  for _, it in ipairs(list.items) do out[#out + 1] = { name = it.title, id = it.id } end
  return out, catalog.list_line(list.command)
end
local function build(pc, panel)
  if entries then return entries end
  local t = os.clock()
  local from_game = catalog.list_actions(game_lists(pc, panel))
  if not from_game then say('no_lists') end
  local items = catalog.items(item_facts(), from_game or CFG.item_actions, CFG.items.show_unpublished,
    CFG.items.hidden_categories)
  local game = catalog.game_commands(game_commands(pc), CFG.text.game_detail, params)
  local server = catalog.host_commands(host)
  local own = own_rows()
  local game_macro_list, macro_line = game_macros(pc, panel)
  local macros = catalog.macros(game_macro_list or CFG.macros, macro_line or CFG.run_macro)
  entries = {}
  for _, list in ipairs({ items, server, game, macros, own }) do
    for _, e in ipairs(list) do entries[#entries + 1] = e end
  end
  say('entries', { items = #items, game = #game, server = #server, own = #own, macros = #macros,
    from = game_macro_list and 'the game' or 'config.lua' })
  trace('reading the rows', t)
  return entries
end
-- The lines run before, as rows first in line while nothing is typed; each offers Undo when a rule in
-- config.lua knows the line that undoes it.
local function with_recent()
  local all, first = {}, {}
  for i, line in ipairs(recent) do
    local acts = { { label = 'Run', line = line } }
    local undo = catalog.opposite(line, CFG.opposites, WORD)
    if undo then acts[2] = { label = 'Undo', line = undo } end
    all[#all + 1] = { key = 'recent:' .. i, name = line, kind = 'recent', detail = CFG.text.recent_detail,
      actions = acts, args = {} }
    first[all[#all].key] = true
  end
  for _, e in ipairs(entries or {}) do all[#all + 1] = e end
  return all, first
end

-- ---- the widgets -------------------------------------------------------------------------------

local shell, shown, ui, font
local function make(tree, path)
  local cls = StaticFindObject(path)
  if not valid(cls) then say('missing', { what = path }); return nil end
  local w = StaticConstructObject(cls, tree)
  if valid(w) then return w end
end
local function sized(size)
  return { FontObject = font.FontObject, TypefaceFontName = font.TypefaceFontName, Size = size }
end
local function set_color(t, color)
  if valid(t) then ucall(t, G.set_text_color, { SpecifiedColor = color, ColorUseRule = 0 }) end
end
local function text_block(tree, size, color)
  local t = make(tree, G.text_block)
  if not t then return nil end
  if font then ucall(t, G.set_font, sized(size)) end
  set_color(t, color)
  return t
end
local function set_text(t, s) if valid(t) then ucall(t, G.set_text, FText(s or '')) end end
-- in: the kind of box child goes in (nil a vertical one, true a horizontal one, 'wrap' a wrap box),
-- for the padding call its slot takes.
local function add(box, child, pad, in_kind)
  local ok, slot = ucall(box, G.add_child, child)
  if ok and valid(slot) and pad then
    local set = in_kind == 'wrap' and G.set_slot_padding_w or in_kind and G.set_slot_padding_h or G.set_slot_padding_v
    ucall(slot, set, pad)
  end
end
local function margin(l, t, r, b) return { Left = l, Top = t, Right = r or l, Bottom = b or t } end

-- The shell: the game's cheat panel, made once (or one an earlier load of this script left taken
-- over), every part of it hidden, the palette added to its canvas.
local function build_ui(w, pc)
  local tree, root
  pcall(function() tree = w[G.tree]; root = tree[G.root] end)
  local canvas_cls = StaticFindObject(G.canvas)
  if not (valid(root) and valid(canvas_cls) and root:IsA(canvas_cls)) then
    say('no_part', { what = 'the game panel has no canvas at its root' }); return nil
  end
  -- The font of the game's own command line, so the palette's text looks like the game's.
  local ok, count = ucall(root, G.child_count)
  local function find(widget, want)
    if widget:GetFName():ToString() == want then return widget end
    local container = StaticFindObject('/Script/UMG.PanelWidget')
    if not widget:IsA(container) then return nil end
    local got, n = ucall(widget, G.child_count)
    for i = 0, (got and n or 0) - 1 do
      local has, c = ucall(widget, G.child_at, i)
      local found = has and valid(c) and find(c, want)
      if found then return found end
    end
  end
  local label = find(root, G.font_from)
  pcall(function() font = label[G.label_font] end)
  for i = 0, (ok and count or 0) - 1 do
    local got, child = ucall(root, G.child_at, i)
    if got and valid(child) then ucall(child, G.set_visibility, G.collapsed) end
  end

  local u = { rows = {} }
  u.frame = make(tree, G.border)
  local col = make(tree, G.vertical)
  if not (u.frame and col) then return nil end
  ucall(u.frame, G.set_brush_color, C.surface)
  ucall(u.frame, G.set_border_padding, margin(CFG.padding, CFG.padding))
  ucall(u.frame, G.set_content, col)
  local placed, slot = ucall(root, G.add_to_canvas, u.frame)
  if placed and valid(slot) then
    local at = CFG.layout
    ucall(slot, G.set_anchors, { Minimum = { X = at.left, Y = at.top }, Maximum = { X = at.right, Y = at.top } })
    ucall(slot, G.set_alignment, { X = 0.0, Y = 0.0 })
    ucall(slot, G.set_auto_size, true)
    ucall(slot, G.set_offsets, { Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
    ucall(slot, G.set_z, 10)
  end

  local tabs = make(tree, G.horizontal)
  local title = text_block(tree, CFG.sizes.title, C.accent)
  set_text(title, CFG.text.title)
  add(tabs, title, margin(0, 0, 18, 0), true)
  u.tabs = {}
  -- Tabs, actions and rows each sit in a border of their own: the border is what reports the mouse
  -- over it (IsHovered), so a click can find its target.
  local function hit_area(content, pad)
    local b = make(tree, G.border)
    if not b then return nil end
    ucall(b, G.set_visibility, G.clickable)
    ucall(b, G.set_brush_color, C.row)
    ucall(b, G.set_border_padding, pad or margin(0, 0))
    ucall(b, G.set_content, content)
    return b
  end
  u.tab_areas = {}
  for i, tab in ipairs(CFG.tabs) do
    local t = text_block(tree, CFG.sizes.small, C.muted)
    set_text(t, tab.label)
    u.tab_areas[i] = hit_area(t, margin(4, 2))
    add(tabs, u.tab_areas[i], margin(0, 1, 6, 0), true)
    u.tabs[i] = t
  end
  u.count = text_block(tree, CFG.sizes.small, C.muted)
  add(tabs, u.count, margin(0, 3, 0, 0), true)
  add(col, tabs, margin(0, 0, 0, 10))

  local field = make(tree, G.border)
  u.box = make(tree, G.textbox_class)
  if not (field and u.box) then return nil end
  ucall(field, G.set_brush_color, C.field)
  ucall(field, G.set_border_padding, margin(10, 6))
  ucall(field, G.set_content, u.box)
  if font then ucall(u.box, G.textbox_font, sized(CFG.sizes.field)) end
  pcall(function() u.box[G.textbox_style][G.style_color] = { SpecifiedColor = C.text, ColorUseRule = 0 } end)
  add(col, field, margin(0, 0, 0, 8))

  -- The rows scroll in the engine's own scroll box (mouse wheel and scrollbar), at most
  -- list_height tall; up to max_rows rows are made once and reused for each search.
  local sized_box, scroll = make(tree, G.size_box), make(tree, G.scroll_box)
  if not (sized_box and scroll) then return nil end
  ucall(sized_box, G.set_max_height, CFG.list_height)
  ucall(sized_box, G.set_content, scroll)
  add(col, sized_box)
  u.scroll = scroll
  for i = 1, CFG.max_rows do
    local row = make(tree, G.border)
    local lines = make(tree, G.vertical)
    local name = text_block(tree, CFG.sizes.row, C.text)
    local detail = text_block(tree, CFG.sizes.detail, C.dim)
    if not (row and lines and name and detail) then return nil end
    ucall(row, G.set_brush_color, C.row)
    ucall(row, G.set_border_padding, margin(10, 4))
    ucall(row, G.set_content, lines)
    add(lines, name)
    add(lines, detail)
    ucall(scroll, G.add_child, row)
    u.rows[i] = { frame = row, name = name, detail = detail }
  end
  -- How the chosen command is written: its parameters, under the list.
  u.signature = text_block(tree, CFG.sizes.row, C.accent)
  add(col, u.signature, margin(0, 8, 0, 0))
  -- The chosen row's actions, one label each so a click can pick one.
  local acts = make(tree, G.horizontal)
  u.acts, u.act_areas = {}, {}
  for i = 1, 4 do
    u.acts[i] = text_block(tree, CFG.sizes.row, C.muted)
    u.act_areas[i] = hit_area(u.acts[i], margin(6, 2))
    add(acts, u.act_areas[i], margin(0, 0, 10, 0), true)
  end
  add(col, acts, margin(0, 8, 0, 0))
  -- Who an item is for: the player, each other player in the game's own player list, everyone.
  local for_row = make(tree, G.horizontal)
  u.for_row, u.targets, u.target_areas = for_row, {}, {}
  local for_label = text_block(tree, CFG.sizes.small, C.muted)
  set_text(for_label, CFG.text.for_label)
  add(for_row, for_label, margin(0, 3, 8, 0), true)
  for i = 1, CFG.max_targets do
    u.targets[i] = text_block(tree, CFG.sizes.small, C.muted)
    u.target_areas[i] = hit_area(u.targets[i], margin(6, 2))
    add(for_row, u.target_areas[i], margin(0, 0, 6, 0), true)
  end
  add(col, for_row, margin(0, 6, 0, 0))
  u.preview = text_block(tree, CFG.sizes.small, C.muted)
  add(col, u.preview, margin(0, 4, 0, 0))
  -- What was sent, and the server's answer under it: wrapped, one line per line of the answer.
  u.receipt = text_block(tree, CFG.sizes.small, C.accent)
  add(col, u.receipt, margin(0, 6, 0, 0))
  u.answer_area = make(tree, G.border)
  u.answer = text_block(tree, CFG.sizes.small, C.text)
  if not (u.answer_area and u.answer) then return nil end
  ucall(u.answer, G.set_wrap, true)
  ucall(u.answer_area, G.set_brush_color, C.field)
  ucall(u.answer_area, G.set_border_padding, margin(8, 5))
  ucall(u.answer_area, G.set_content, u.answer)
  ucall(u.answer_area, G.set_visibility, G.collapsed)
  add(col, u.answer_area, margin(0, 4, 0, 0))
  -- The keys along the bottom. One that is a game action (h.action) is the game's own hint, which
  -- draws the player's own key for it ("Close ( Esc )"); the rest, keys the game has no action for,
  -- are a word and the key in a box made to look like it.
  local hints = make(tree, G.wrap_box)  -- wraps onto a second line when the panel is narrow
  local hint_cls, lib = StaticFindObject(G.hint_widget), StaticFindObject(G.widgets)
  u.game_hints, u.more_hints = {}, {}
  for _, h in ipairs(CFG.hints) do
    local game_hint
    if h.action and valid(hint_cls) then
      pcall(function() game_hint = lib:Create(pc, hint_cls, pc) end)
      if valid(game_hint) then
        -- Its text is set once it is in the panel: added, it starts again from its designer text.
        add(hints, game_hint, margin(0, 1, 16, 2), 'wrap')
        if not h.core then
          u.more_hints[#u.more_hints + 1] = game_hint
          ucall(game_hint, G.set_visibility, G.collapsed)
        end
        if ucall(game_hint, G.hint_set_text, FText(route.fill(G.hint_text, h))) then
          u.game_hints[#u.game_hints + 1] = { widget = game_hint, text = route.fill(G.hint_text, h) }
        else
          ucall(game_hint, G.set_visibility, G.collapsed)
          game_hint = nil
        end
      end
    end
    if not game_hint then
      local group = make(tree, G.horizontal)  -- one hint, kept on one line
      local word = text_block(tree, CFG.sizes.small, C.text)
      set_text(word, h.label .. ' (')
      add(group, word, margin(0, 3, 4, 0), true)
      local cap = text_block(tree, CFG.sizes.small, C.accent)
      set_text(cap, h.key)
      local frame = make(tree, G.border)
      ucall(frame, G.set_brush_color, C.key)
      ucall(frame, G.set_border_padding, margin(5, 1))
      ucall(frame, G.set_content, cap)
      add(group, frame, margin(0, 1, 4, 0), true)
      local close = text_block(tree, CFG.sizes.small, C.text)
      set_text(close, ')')
      add(group, close, margin(0, 3, 0, 0), true)
      add(hints, group, margin(0, 0, 16, 2), 'wrap')
      if not h.core then
        u.more_hints[#u.more_hints + 1] = group
        ucall(group, G.set_visibility, G.collapsed)
      end
    end
  end
  add(col, hints, margin(0, 8, 0, 0))
  return u
end

local function make_shell(pc)
  if valid(shell) and ui then return shell end
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
  local t = os.clock()
  ui = build_ui(w, pc)
  trace('building the palette', t)
  if not ui then return nil end
  shell, shown = w, false
  return w
end

-- ---- what it shows -----------------------------------------------------------------------------

local query, tab, found, chosen, action = nil, 1, {}, 1, 1
local empty_tab = {}  -- tabs with nothing in them, not shown
local targets, target = {}, 1  -- who an item is for: { label, who } each, who nil for the player
-- The players now in the game, from its own player list (this player first, as "me"), then everyone.
local function read_targets(pc)
  local out, mine = { { label = CFG.text.me } }, nil
  -- Others are reached through a Moonpool server's console: without one (no host-commands.lua) the
  -- player is the only target, and the line is not shown.
  if type(host) ~= 'table' then return out end
  pcall(function() mine = pc.PlayerState end)
  local state = FindFirstOf(G.game_state)
  local list
  if valid(state) then pcall(function() list = state[G.player_array] end) end
  pcall(function()
    for i = 1, list:GetArrayNum() do
      local ps = list[i]
      if valid(ps) and not (valid(mine) and ps:GetAddress() == mine:GetAddress()) then
        local name
        pcall(function() name = ps[G.player_name]:ToString() end)
        if name and name ~= '' and #out < CFG.max_targets - 1 then out[#out + 1] = { label = name, who = name } end
      end
    end
  end)
  out[#out + 1] = { label = CFG.text.everyone, who = CFG.everyone_word }
  return out
end
-- Rows that can be for someone else: the game's items.
local function for_anyone(e) return e and e.kind == 'item' end
-- The line an action sends: for someone else, the action's own line run as them by the server.
local function line_for(e, act, count)
  local line = catalog.draft(e, act, { count = count })
  if for_anyone(e) and targets[target] and targets[target].who then
    return catalog.for_others(CFG.for_others, WORD, targets[target].who, line)
  end
  return line
end
local function chosen_entry() return found[chosen] end
-- The chosen row's colour, its actions and the line Enter sends; the row is scrolled into view.
local function mark()
  if not ui then return end
  for i, r in ipairs(ui.rows) do
    if found[i] then ucall(r.frame, G.set_brush_color, i == chosen and C.chosen or C.row) end
  end
  -- The widget, no animation, just into view (EDescendantScrollDestination 0), no padding.
  if ui.rows[chosen] then ucall(ui.scroll, G.scroll_into_view, ui.rows[chosen].frame, false, 0, 0.0) end
  local e = chosen_entry()
  set_text(ui.signature, e and e.signature or '')
  local acts = e and e.actions or {}
  for i, t in ipairs(ui.acts) do
    local a = #acts > 1 and acts[i]
    set_text(t, a and a.label or '')
    set_color(t, i == action and C.amber or C.muted)
    ucall(ui.act_areas[i], G.set_brush_color, a and i == action and C.chosen or C.row)
  end
  local is_item = for_anyone(e) and #targets > 1
  ucall(ui.for_row, G.set_visibility, is_item and G.shown or G.collapsed)
  for i, t in ipairs(ui.targets) do
    local who = is_item and targets[i]
    ucall(ui.target_areas[i], G.set_visibility, who and G.clickable or G.collapsed)
    if who then
      set_text(t, who.label)
      set_color(t, i == target and C.amber or C.muted)
      ucall(ui.target_areas[i], G.set_brush_color, i == target and C.chosen or C.row)
    end
  end
  local act = e and (e.actions[action] or e.actions[1])
  local _, count = route.count(query or '')
  set_text(ui.preview, act and route.fill(CFG.text.preview, { line = line_for(e, act, count) }) or '')
end
-- The rows themselves: written once per search.
local function draw()
  if not ui then return end
  for i, t in ipairs(ui.tabs) do set_color(t, i == tab and C.amber or C.muted) end
  for i, r in ipairs(ui.rows) do
    local e = found[i]
    ucall(r.frame, G.set_visibility, e and G.clickable or G.collapsed)
    if e then
      set_text(r.name, e.name)
      set_text(r.detail, e.detail)
    end
  end
  ucall(ui.scroll, G.scroll_to_start)
  mark()
end
local function search(text)
  local t = os.clock()
  local wanted, count = route.count(text)
  local rows, recent_first = with_recent()
  rows = catalog.searchable(rows, CFG.tabs[tab].kind, wanted)
  local list, all = catalog.search(rows, wanted, CFG.max_rows, CFG.tabs[tab].kind, recent_first)
  found, chosen, action = list, 1, 1
  local found_text = all > #found and CFG.text.found_more or all == 1 and CFG.text.found_one or CFG.text.found
  set_text(ui.count, route.fill(found_text, { shown = #found, count = all }))
  if #found == 0 and text ~= '' then set_text(ui.receipt, CFG.text.none); set_color(ui.receipt, C.muted); ui.none = true
  elseif ui.none then set_text(ui.receipt, ''); ui.none = false end
  draw()
  trace('searching', t)
  return count
end
local function box_text()
  local text = ''
  if ui then pcall(function() text = select(2, ucall(ui.box, G.textbox_get)):ToString() end) end
  return text
end
local function set_box(text) if ui then ucall(ui.box, G.textbox_set, FText(text)) end end
local function focus_box()
  if not ui then return end
  ucall(ui.box, G.keyboard_focus)
  -- CommonUI gives the panel's own focus target the keyboard when it activates, after this runs.
  ExecuteInGameThreadWithDelay(150, function() if shown and ui then ucall(ui.box, G.keyboard_focus) end end)
end

-- What the player looks at, shown when the palette opens.
local function looking_at(pc)
  local comp, actor
  pcall(function() comp = pc[G.interact] end)
  if not valid(comp) then return nil end
  local ok, a = ucall(comp, G.target)
  actor = ok and a
  if not valid(actor) then return nil end
  local got, at = ucall(actor, G.location)
  if not got or not at then return nil end
  local function m(v) return math.floor((v or 0) / 100 + 0.5) end
  local name = actor:GetClass():GetFName():ToString()
  return route.fill(CFG.text.looking, { name = name, x = m(at.X), y = m(at.Y), z = m(at.Z) })
end

-- ---- sending -----------------------------------------------------------------------------------

-- local_run: through the game's own console on this PC (a macro, which sends its lines itself).
local last_sent  -- the line most recently sent, to match the server's answer to it
local function send(pc, line, local_run)
  -- Sent once, never retried: a call that failed after it left would run the line twice.
  local went
  if local_run then
    local system = StaticFindObject(G.system)
    went = valid(system) and pcall(function() system:ExecuteConsoleCommand(pc, line, pc) end)
  else
    went = pcall(function() pc:ServerCheat(line) end)
  end
  if not went then
    say('failed', { what = G.server_cheat, tries = 1, error = line })
    set_text(ui.receipt, route.fill(CFG.log.failed, { what = G.server_cheat, tries = 1, error = line }))
    set_color(ui.receipt, C.failed)
    return false
  end
  last_sent = line
  local undo = catalog.opposite(line, CFG.opposites, WORD)
  set_text(ui.receipt, route.fill(undo and CFG.text.undo or CFG.text.sent, { line = line, undo = undo }))
  set_text(ui.preview, '')  -- the line went: the receipt says what was sent; the preview returns on a move
  set_color(ui.receipt, C.accent)
  ucall(ui.answer_area, G.set_visibility, G.collapsed)  -- the last answer goes; this line's comes under it
  ui.none = false
  return true
end
-- A line as typed: one of the game's commands as it is, anything else for the server's console.
local MACRO_WORD = (CFG.run_macro:match('^(%S+)') or ''):lower()
local function send_typed(pc, said)
  -- A macro runs on this PC, which sends its lines one by one; the server refuses it whole.
  if (said:match('^%s*(%S+)') or ''):lower() == MACRO_WORD then
    if send(pc, said, true) then remember(said) end
    return
  end
  local where, text = route.route(said, game_commands(pc), WORD)
  if not where then return end
  if send(pc, where == route.CONSOLE and text or said) then remember(said) end
end

local waiting  -- a line for everyone, sent on a second Enter (catalog.confirm)
local function run()
  if not shown or not ui then return end
  local pc = live(G.controller)[1]
  if not pc then return end
  local text = box_text()
  local _, count = route.count(text)
  local e = chosen_entry()
  -- A command followed by what it needs ("give john glass 10") goes as typed.
  local first_word = text:match('^%s*(%S+)%s+%S') or ''
  local known = game_commands(pc) or {}
  local typed_command = first_word ~= '' and (known[first_word:lower()] or first_word:lower() == WORD
    or (host and host.commands and (host.commands[first_word:lower()] or (host.verbs or {})[first_word:lower()])))
  if typed_command or not e then
    if text ~= '' then send_typed(pc, text) end
    set_box('')
    return
  end
  local act = e.actions[action] or e.actions[1]
  if for_anyone(e) and targets[target] and targets[target].who then
    local line = line_for(e, act, count)
    if targets[target].who == CFG.everyone_word then
      local go
      go, waiting = catalog.confirm(waiting, line, os.time(), CFG.confirm_s)
      if not go then
        set_text(ui.receipt, route.fill(CFG.text.confirm, { line = line }))
        set_color(ui.receipt, C.failed)
        return
      end
    end
    if send(pc, line) then remember(line) end
    return
  end
  local line, missing = catalog.line(e, act, { count = count })
  if not line then
    set_text(ui.receipt, route.fill(CFG.text.missing, { arg = missing }))
    set_box(e.name .. ' ')
    focus_box()
    return
  end
  if act.local_run then
    if send(pc, line, true) then remember(line) end
  elseif e.kind == 'server' or e.kind == 'recent' or e.kind == 'own' then send_typed(pc, line)
  elseif send(pc, line) then remember(line) end
end

-- Tab: the exact line the chosen action would send, into the search line to change before Enter
-- (the line up to the first argument still needed, when one is).
local function edit()
  if not shown or not ui then return end
  local e = chosen_entry()
  local act = e and (e.actions[action] or e.actions[1])
  if act then
    local _, count = route.count(box_text())
    set_box(catalog.draft(e, act, { count = count }))
  end
  focus_box()
end
-- F1: the other key hints, shown or put away.
local keys_shown = false
local function toggle_keys()
  if not (shown and ui) then return end
  keys_shown = not keys_shown
  for _, w in ipairs(ui.more_hints) do ucall(w, G.set_visibility, keys_shown and G.shown or G.collapsed) end
end
-- Ctrl and Up or Down: who an item is for.
local function step_target(step)
  if not shown or #targets == 0 then return end
  target = (target - 1 + step) % #targets + 1
  mark()
end
-- Ctrl and an arrow: the chosen row's next or previous action.
local function step_action(step)
  local e = shown and chosen_entry()
  if not (e and #e.actions > 1) then return end
  action = (action - 1 + step) % #e.actions + 1
  mark()
end
local function nav(step)
  if not shown or #found == 0 then return end
  chosen = math.max(1, math.min(#found, chosen + step))
  action = 1
  mark()
end

-- Alt and a number: that tab.
local function pick_tab(n)
  if not (shown and CFG.tabs[n]) or empty_tab[n] then return end
  tab = n
  query = nil  -- searched again on the next read
end

-- A click only highlights: a tab shows it, a row is chosen, an action is picked. Enter sends.
-- The target is whichever of them has the mouse over it.
local function hovered(widget)
  local ok, over = ucall(widget, G.is_hovered)
  return ok and over == true
end
local function click()
  if not (shown and ui) then return end
  for i, area in ipairs(ui.tab_areas) do
    if hovered(area) then tab = i; query = nil; return end
  end
  for i, r in ipairs(ui.rows) do
    if found[i] and hovered(r.frame) then
      if i ~= chosen then chosen, action = i, 1 end
      return mark()
    end
  end
  for i, area in ipairs(ui.target_areas) do
    if targets[i] and hovered(area) then target = i; return mark() end
  end
  local e = chosen_entry()
  for i, area in ipairs(ui.act_areas) do
    if e and e.actions[i] and hovered(area) then action = i; return mark() end
  end
end

-- An answer the server sent this player, as the game's notification: shown in the receipt line while
-- the palette shows. main.lua hooks the notification at load; a hook registered later, from a game
-- thread callback, lost its function in UE4SS and crashed the game when the next answer came.
local function answer(header, text)
  if not (shown and ui) or (header == '' and text == '') then return end
  -- Only the answer to the line just sent: the server titles its answer with the line it got. Other
  -- notifications of the game's are left to the game's own card.
  local function plain(t) return tostring(t or ''):match('^%s*(.-)%s*$'):lower() end
  if plain(header) ~= plain(last_sent) then return end
  local lines = {}
  for l in (text .. '\n'):gmatch('([^\r\n]*)\r?\n') do
    if l ~= '' and #lines < CFG.answer_lines then lines[#lines + 1] = l end
  end
  set_text(ui.receipt, header)
  set_color(ui.receipt, C.accent)
  set_text(ui.answer, table.concat(lines, '\n'))
  ucall(ui.answer_area, G.set_visibility, #lines > 0 and G.shown or G.collapsed)
end

-- ---- showing and closing -----------------------------------------------------------------------

local function input_mode(pc, widget, on)
  local lib = StaticFindObject(G.widgets)
  if on then call(G.widgets, function() lib:SetInputMode_GameAndUIEx(pc, widget, 0, false, false) end)
  else call(G.widgets, function() lib:SetInputMode_GameOnly(pc, false) end) end
  pcall(function() pc.bShowMouseCursor = on end)
end
local function give_back(pc)
  input_mode(pc, shell, false)
  for _, part in ipairs(CFG.give_back) do
    local ok, stuck = ucall(pc, part.held)
    if ok and stuck then ucall(pc, part.release); say('gave_back', { what = part.name }) end
  end
end

-- The search line is read every read_ms while the palette shows, and searched again when it changed.
-- The loop runs on the game thread itself (UE4SS's LoopInGameThreadWithDelay): a loop on UE4SS's async
-- thread that queued work for the game thread ten times a second broke a Lua reference now and then,
-- and the game crashed running it. It is cancelled when the palette closes.
local reading
local function follow()
  if reading then return end
  reading = LoopInGameThreadWithDelay(CFG.read_ms, function()
    if not (shown and ui) then return end
    -- The search line keeps the keyboard: the game takes it back when its window comes to the front.
    local ok, has = ucall(ui.box, G.has_focus)
    if ok and not has then ucall(ui.box, G.keyboard_focus) end
    local text = box_text()
    if text ~= query then query = text; search(text) end
  end)
end
local function stop_following()
  if reading then pcall(CancelDelayedAction, reading); reading = nil end
end

-- A second press while the first is still being carried out is ignored: opening and closing in the
-- same instant, on a panel only just made, crashed the game.
local busy = false
local function toggle()
  if busy then return end
  busy = true
  ExecuteInGameThreadWithDelay(CFG.toggle_gap_ms, function() busy = false end)
  local t = os.clock()
  local pc = live(G.controller)[1]
  if not pc then return end
  -- It opens only once the player has a body in the world: the game crashed making the panel while
  -- the world was still loading. Closing needs no body.
  local pawn
  pcall(function() pawn = pc.Pawn end)
  if not shown and not valid(pawn) then return end
  local w = make_shell(pc)
  if not w then return end
  local want = not shown
  if want then
    build(pc, w)  -- before the panel shows: reading the game's lists opens and closes them
    -- A tab with nothing in it is not shown: without a Moonpool server the Server tab has no commands,
    -- and Mine is empty until a player adds rows.
    local have = {}
    for _, e in ipairs(entries or {}) do have[e.kind] = true end
    for i, def in ipairs(CFG.tabs) do
      empty_tab[i] = def.kind ~= nil and def.kind ~= 'recent' and not have[def.kind]
      if ui.tab_areas[i] then ucall(ui.tab_areas[i], G.set_visibility, empty_tab[i] and G.collapsed or G.clickable) end
    end
  end
  if not ucall(w, G.set_visibility, want and G.shown or G.hidden) then return end
  shown = want
  ucall(w, want and G.activate or G.deactivate)
  input_mode(pc, w, want)
  if want then
    set_box('')
    query = nil
    targets, target = read_targets(pc), 1
    -- The game's own hints show their designer text until shown once, so theirs is set on the first
    -- opening, and only then: set again, the widget draws a stray glyph in place of the hint.
    for _, gh in ipairs(ui.game_hints or {}) do
      if valid(gh.widget) and not gh.set then
        gh.set = true
        pcall(function() gh.widget.OriginalText = FText(gh.text) end)
        pcall(function() gh.widget.Text = FText(gh.text) end)
        ucall(gh.widget, G.hint_set_text, FText(gh.text))
        ucall(gh.widget, G.hint_rebuild)  -- it draws its text and key caps when its mappings are rebuilt
      end
    end
    set_text(ui.receipt, looking_at(pc) or '')
    set_color(ui.receipt, C.muted)
    focus_box()
    follow()
    trace('opening', t)
  else
    local system = StaticFindObject(G.system)
    for _, command in ipairs(CFG.close_commands) do
      call(command, function() system:ExecuteConsoleCommand(pc, command, pc) end)
    end
    stop_following()
    give_back(pc)
  end
end
local function back() if shown then toggle() end end

return { toggle = toggle, back = back, nav = nav, run = run, edit = edit, step_action = step_action,
  step_target = step_target, toggle_keys = toggle_keys,
  click = click, pick_tab = pick_tab, answer = answer, config = CFG, say = say }
