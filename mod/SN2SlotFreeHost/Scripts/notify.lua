-- notify.lua: one-shot player notifications for operator messages and restart warnings.
local M = {}
local said = {}
local function once(log, key, text) if not said[key] then said[key] = true; log(text) end end

function M.data(kind, header, text, duration, make_text)
  make_text = make_text or function(v) return v end
  return { HeaderText = make_text(header or ''), HeaderSubText = make_text(''),
    Text = make_text(text or ''), ButtonText = make_text(''),
    Type = kind == 'warning' and 6 or 5, NotificationDuration = duration or 8.0 }
end

function M.send(g, players, kind, header, text, duration)
  if #players == 0 then return true end
  local data = M.data(kind, header, text, duration, g.text)
  local static = g.find('/Script/UWENotifications.Default__UWENotificationStatics')
  if static then
    local ok, err = pcall(function() static:SendNotificationToPlayers(g.world(), data, players) end)
    if ok then once(g.log, 'static-ok', 'notifications: game static path works'); return true end
    once(g.log, 'static-fail', 'notifications: static path failed once: ' .. tostring(err))
  else once(g.log, 'static-missing', 'notifications: static object missing once') end
  local any = false
  for _, player in ipairs(players) do
    local ok, err = pcall(function() player.NotificationComponent:ClientNotify(data) end)
    if ok then any = true
    else once(g.log, 'client-fail', 'notifications: ClientNotify failed once: ' .. tostring(err)) end
  end
  if any then once(g.log, 'client-ok', 'notifications: ClientNotify fallback works') end
  return any
end

-- Who a notice goes to: every live player but the host, or only the names a notice
-- lists (a join greeting goes to the joiner, not to everyone already in).
function M.targets(live, host, only)
  local wanted
  if type(only) == 'table' then
    wanted = {}
    for _, name in ipairs(only) do wanted[name] = true end
  end
  local players, names = {}, {}
  for _, p in ipairs(live) do
    if p.name ~= host and (not wanted or wanted[p.name]) then
      players[#players + 1] = p.player
      names[#names + 1] = p.name
    end
  end
  return players, names
end

return M
