-- admin_signal.lua: pure policy for commands entered by renaming a PDA
-- The game, clock and command handlers are supplied through `g`, so this file
-- is exercised by tests/lua/admin_signal_spec.lua without UE4SS.
local M = {}

M.MAX_REPLY = 40
M.RATE_SECONDS = 3
M.CONFIRM_SECONDS = 60

local function trim(s) return (s or ''):match('^%s*(.-)%s*$') end
local function short(s)
  s = tostring(s or ''):gsub('[\r\n]+', ' ')
  if #s > M.MAX_REPLY then s = s:sub(1, M.MAX_REPLY - 3) .. '...' end
  return s
end

-- Epic (EOS) product user IDs only. A display name can be taken and the Steam ID in the login
-- line is what the client says; the EOS ID comes from the connection itself.
function M.admins(csv)
  local out = {}
  for item in tostring(csv or ''):gmatch('[^,]+') do
    item = trim(item)
    if #item == 32 and item:match('^%x+$') then out[item:lower()] = true end
  end
  return out
end

-- The engine logs which EOS ID each connection object belongs to; no player text is involved.
function M.note_connection(state, line)
  local id, connection = line:match('Added client connection: %[UNetConnection%] RemoteAddr: EOS:(%x+), Name: ([%w_]+)')
  if connection then state.ids[connection] = id:lower() end
  -- A closed connection leaves nothing behind for a later one with the same name.
  connection = line:match('UNetConnection::Close: %[UNetConnection%] RemoteAddr: [^,]*, Name: ([%w_]+)')
  if connection then state.ids[connection] = nil end
end

-- For the operator's ADMINS list only, never for a decision: the name here is the client's.
function M.login_label(line)
  return line:match('Login request: %?Name=([^?]*).-userId: EOS:|(%x+)')
end

function M.connection_id(state, connection) return connection and state.ids[connection] or nil end

function M.authorized(admins, sender)
  return sender.eos ~= nil and admins[sender.eos] == true
end

function M.parse(text, prefix)
  prefix = prefix or '!'
  if prefix == '' or type(text) ~= 'string' or text:sub(1, #prefix) ~= prefix then return nil end
  local body = trim(text:sub(#prefix + 1))
  local cmd, rest = body:match('^(%S+)%s*(.-)$')
  if not cmd then return { command = 'help', args = {} } end
  cmd = cmd:lower()
  local args = {}
  for word in rest:gmatch('%S+') do args[#args + 1] = word end
  return { command = cmd, args = args, raw = rest }
end

function M.new(opts)
  opts = opts or {}
  return { admins = M.admins(opts.admins), ids = {}, prefix = opts.prefix or '!', last = {}, restart = {} }
end

local function reply(ok, text) return { ok = ok, text = short(text), color = ok and 'green' or 'red' } end
local function line_reply(ok, lines)
  local out = {}
  for _, line in ipairs(lines or {}) do out[#out + 1] = short(line) end
  return { ok = ok, text = table.concat(out, '\n'), color = ok and 'green' or 'red' }
end

local function result(ok, data, err, success)
  if not ok then return reply(false, err or 'refused') end
  return reply(true, success(data))
end

local function invoke(g, name, args, success)
  local ok, data, err = g.call(name, args)
  return result(ok, data, err, success)
end

function M.run(state, sender, text, g)
  local p = M.parse(text, state.prefix)
  if not p then return nil end
  local key = sender.eos or sender.name or '?'
  local now = g.now()
  local allowed = M.authorized(state.admins, sender)
  if p.command == 'ping' then
    if #p.args ~= 0 then return reply(false, 'use: /ping') end
    local ok, data, err = g.call('ping', { sender = sender, all = allowed })
    if not ok then return reply(false, err or 'ping unavailable') end
    return line_reply(true, data.lines)
  end
  if not allowed then
    -- Ignored without a reply, so nobody can paint other players' signals red;
    -- logged at most once a minute per sender.
    state.denied = state.denied or {}
    local first = not state.denied[key] or now - state.denied[key] >= 60
    if first then state.denied[key] = now end
    return { ok = false, text = 'admins only', silent = true, log = first }
  end
  if state.last[key] and now - state.last[key] < M.RATE_SECONDS then return reply(false, 'please wait a moment') end
  state.last[key] = now

  local a, cmd = p.args, p.command
  if cmd == 'help' then return reply(true, 'cmd kick ping slots time weather') end
  if cmd == 'cmd' then
    -- The game's own console, run on the host as this admin: the same door and the same
    -- switch as moonpool diag console (player in enabled_commands).
    if p.raw == '' then return reply(false, 'use: !cmd LINE') end
    return invoke(g, 'console', { sender = sender, line = p.raw }, function() return 'ran ' .. short(p.raw) end)
  end
  if cmd == 'slots' then
    local n = tonumber(a[1])
    if not n or #a ~= 1 then return reply(false, 'use: !slots 1-63') end
    return invoke(g, 'slots', { slots = n }, function(d) return 'slots now ' .. tostring(d.slots) end)
  end
  if cmd == 'time' then
    if #a ~= 1 then return reply(false, 'use: !time HH:MM|frozen|normal') end
    return invoke(g, 'time', { value = a[1] }, function(d) return 'time ' .. tostring(d.value) end)
  end
  if cmd == 'weather' then
    if #a ~= 1 then return reply(false, 'use: !weather NAME') end
    return invoke(g, 'weather', { value = a[1] }, function(d) return 'weather ' .. tostring(d.value) end)
  end
  if cmd == 'kick' then
    if p.raw == '' then return reply(false, 'use: !kick PLAYER') end
    return invoke(g, 'kick', { player = p.raw }, function() return p.raw .. ' removed' end)
  end
  if cmd == 'unlocks' then
    return invoke(g, 'unlocks', { player = p.raw ~= '' and p.raw or nil }, function() return 'unlocks shared' end)
  end
  if cmd == 'restart' then
    if a[1] == 'cancel' and #a == 1 then
      return invoke(g, 'restart_cancel', {}, function() return 'restart cancelled' end)
    end
    if #a ~= 0 then return reply(false, 'use: !restart [cancel]') end
    state.restart[key] = now
    return reply(true, 'rename to !confirm within 60 sec')
  end
  if cmd == 'confirm' then
    local started = state.restart[key]
    state.restart[key] = nil
    if not started or now - started > M.CONFIRM_SECONDS then return reply(false, 'restart confirmation expired') end
    return invoke(g, 'restart', {}, function() return 'restart requested' end)
  end
  return reply(false, 'unknown command; use !help')
end

return M
