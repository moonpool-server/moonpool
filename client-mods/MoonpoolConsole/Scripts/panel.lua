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
local function ucall(obj, path, ...)
  local fn = StaticFindObject(path)
  if not valid(fn) then say('missing', { what = path }); return false end
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

local panel, shown, trimmed, hooked, commands

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

local function trim(w)
  local base = w:GetFullName():match('^%S+%s+(.*)$')
  local parts, block = {}, nil
  pcall(ForEachUObject, function(o)
    local ok, name = pcall(function() return o:GetFullName() end)
    if not ok or not name then return end
    local part, kind = route.part_of(name, base)
    if part and route.hidden(kind, part, CFG.panel) then parts[#parts + 1] = o end
    if part == CFG.layout.part then block = o end
  end)
  for _, o in ipairs(parts) do ucall(o, G.set_visibility, G.hidden) end
  if valid(block) then dock(block) end
  trimmed = true
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
  if not pc then return nil end
  local where, text = route.route(line, game_commands(pc), CFG.word)
  if where == route.CONSOLE then call(G.typed_line, function() pc:ServerCheat(text) end) end
  return where, text
end

local function hook_typed_lines()
  if hooked or not valid(StaticFindObject(G.typed_line)) then return end
  hooked = pcall(RegisterHook, G.typed_line, function(_, Cmd)
    local ok, err = pcall(function() typed(Cmd:get():ToString()) end)
    if not ok then say('error', { error = err }) end
  end)
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

local function toggle()
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
  else
    close_opened(pc)
  end
end

return { toggle = toggle, typed = typed, config = CFG, say = say }
