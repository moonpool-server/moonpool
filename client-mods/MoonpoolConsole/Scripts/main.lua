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
