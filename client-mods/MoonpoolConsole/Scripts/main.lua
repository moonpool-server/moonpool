-- Moonpool admin console: one key shows the game's own cheat panel, trimmed to a command line and
-- its pick lists, and closes it again with everything it opened. A line typed there that is not one
-- of the game's commands goes to the server's console. The server decides who is an admin and does
-- the work; this mod only shows and sends. Settings, names and messages: config.lua.
local DIR = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('main%.lua$', '')
local panel = dofile(DIR .. 'panel.lua')
local CFG = panel.config

local key = Key[CFG.key]
if not key then
  panel.say('bad_key', { key = CFG.key })
else
  RegisterKeyBind(key, function()
    ExecuteInGameThread(function()
      local ok, err = pcall(panel.toggle)
      if not ok then panel.say('error', { error = err }) end
    end)
  end)
  panel.say('ready', { key = CFG.key })
end
local function bind(name, fn)
  local k = Key[name]
  if not k then panel.say('bad_key', { key = name }); return end
  RegisterKeyBind(k, function()
    ExecuteInGameThread(function()
      local ok, err = pcall(fn)
      if not ok then panel.say('error', { error = err }) end
    end)
  end)
end
bind(CFG.back_key, panel.back)
-- With a list open the keyboard belongs to the list, so the typing keys are read here (config.lua).
for name, char in pairs(CFG.search.keys) do bind(name, function() panel.key(char) end) end
bind(CFG.search.erase, function() panel.key(nil) end)
for name, step in pairs(CFG.nav) do bind(name, function() panel.nav(step) end) end
bind(CFG.run_key, panel.run)

-- Messages the server sends this player, read for the panel (panel.answer): the game's text messages
-- ("Added 10 Glass") and its notifications (the answers to console lines). Each hook is set once the
-- game has loaded its function, on the game thread. Read only.
local function hook(path, read)
  local done = false
  LoopAsync(5000, function()
    if done then return true end
    ExecuteInGameThread(function()
      if done then return end
      local fn = StaticFindObject(path)
      if not (fn and fn:IsValid()) then return end
      RegisterHook(path, function(_, ...)
        local text = read(...)
        if text then pcall(panel.answer, text) end
      end)
      done = true
    end)
    return done
  end)
end
-- A text message is one of the arguments, reading (String="...") in full.
hook(CFG.answer.hook, function(...)
  for _, arg in ipairs({ ... }) do
    local text
    pcall(function() text = arg:get():ToString():match(CFG.answer.pattern) end)
    if text then return text end
  end
end)
-- A notification carries a header (the line that was run) and its text (the answer).
hook(CFG.answer.notify_hook, function(data)
  local header, text = '', ''
  pcall(function() header = data:get().HeaderText:ToString() end)
  pcall(function() text = data:get().Text:ToString() end)
  if text == '' then return nil end
  return header ~= '' and (header .. ': ' .. text) or text
end)
