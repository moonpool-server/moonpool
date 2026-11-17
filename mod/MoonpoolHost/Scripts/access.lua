-- access.lua: name-based in-game enforcement for the operator's ban list.
-- What nothing else provides: the game exposes player names but not Steam IDs
-- to Lua, so Steam-ID enforcement stays in friend-accept.py and this closes the
-- remaining join race for entries made by player name.
local M = {}

function M.names(raw)
  local out = {}
  for line in (raw or ''):gmatch('[^\r\n]+') do
    if not line:match('^%s*#') then
      local id = line:match('^([^\t]+)')
      local steamid = id and #id == 17 and id:sub(1, 4) == '7656' and id:match('^%d+$')
      if id and not steamid then
        out[id:lower()] = true
      end
    end
  end
  return out
end

-- A name is acted on once while present. Leaving clears the guard, so a later
-- rejoin is acted on again. `kick` is the existing host console-command path; it
-- returns false and a reason when it could not run (no host controller), and then
-- the kick is retried on the next tick and the failure logged once, never
-- reported as done.
function M.tick(seen, banned, roster, host, kick, log)
  local present = {}
  for _, p in ipairs(roster or {}) do
    local name = p.name
    if name and name ~= '?' and name ~= host then
      local key = name:lower(); present[key] = true
      if banned[key] and seen[key] ~= true then
        local ok, why = kick(name)
        if ok == false then
          if seen[key] ~= 'failed' then
            log('access: could not remove banned player ' .. name .. ': ' .. tostring(why) .. '; retrying')
          end
          seen[key] = 'failed'
        else
          seen[key] = true
          log('access: removed banned player ' .. name)
        end
      end
    end
  end
  for key in pairs(seen) do if not present[key] then seen[key] = nil end end
end

return M
