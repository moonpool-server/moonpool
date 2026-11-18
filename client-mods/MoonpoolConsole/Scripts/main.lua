-- Moonpool admin palette: one key shows a search over the game's items and commands and the server's
-- commands, and closes it again. The server decides who is an admin and does the work; this mod only
-- shows and sends. Settings, names and messages: config.lua.
local DIR = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('main%.lua$', '')
local palette = dofile(DIR .. 'palette.lua')
local CFG = palette.config

-- A key bound to fn, which runs on the game thread; an error is logged, never thrown into the game.
-- With trace on, each key is logged as it is acted on, so the last line before a crash names it.
local function bind(name, fn, modifier)
  local k = Key[name]
  if not k then palette.say('bad_key', { key = name }); return false end
  local function act()
    ExecuteInGameThread(function()
      if CFG.trace then palette.say('key', { what = (modifier and modifier .. '+' or '') .. name }) end
      local ok, err = pcall(fn)
      if not ok then palette.say('error', { error = err }) end
    end)
  end
  if modifier then
    if not ModifierKey[modifier] then palette.say('bad_key', { key = modifier }); return false end
    RegisterKeyBind(k, { ModifierKey[modifier] }, act)
  else
    RegisterKeyBind(k, act)
  end
  return true
end
if bind(CFG.key, palette.toggle) then palette.say('ready', { key = CFG.key }) end
-- The rest do nothing while the palette is hidden, so each key keeps its meaning in the game.
bind(CFG.back_key, palette.back)
bind(CFG.run_key, palette.run)
bind(CFG.edit_key, palette.edit)
for name, step in pairs(CFG.action_keys) do
  bind(name, function() palette.step_action(step) end, CFG.action_modifier)
end
for name, step in pairs(CFG.nav) do bind(name, function() palette.nav(step) end) end
for name, step in pairs(CFG.page_keys) do bind(name, function() palette.nav(step * CFG.page_rows) end) end
bind(CFG.click_key, palette.click)
for n, name in ipairs(CFG.tab_number_keys) do
  if CFG.tabs[n] then bind(name, function() palette.pick_tab(n) end, CFG.tab_number_modifier) end
end
-- The server's answers: its notification to this player, read (header and text, nothing written) and
-- handed to the palette on the game thread. Registered here, once, at load.
if CFG.answers then
  local ok, err = pcall(RegisterHook, CFG.game.notify, function(_, data)
    local header, text = '', ''
    pcall(function()
      local d = data:get()
      header = d.HeaderText:ToString()
      text = d.Text:ToString()
    end)
    ExecuteInGameThread(function() pcall(palette.answer, header, text) end)
  end)
  if not ok then palette.say('no_answers', { error = err }) end
end
