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
