-- Control-queue validation for SN2SlotFreeHost. Pure Lua with no game calls, so
-- it is tested outside the game (tests/lua/protocol_spec.lua).
local M = {}

M.VERSION = 1
M.ACCEPTED_VERSIONS = { 1 }
M.MOD_VERSION = '1.0.0'
M.MAX_AGE_SECONDS = 120
M.MAX_BYTES = 4096
M.MAX_RESPONSE_BYTES = 65536
-- Every command the mod will ever act on. config.json can only narrow this.
M.ALLOWLIST = {
  status = { args = {} },
  players = { args = {} },
  host = { args = {} },
  receipt = { args = {} },
  -- A console command run server-side as one named player. Off by default.
  player = { args = { player = 'string', command = 'string' } },
  -- Remove one connected player; the mod builds the line, run as the host.
  kick = { args = { player = 'string' } },
  save = { args = {} },
  -- Real player slots, changed live; the mod checks the range (idle.lua).
  slots = { args = { slots = 'number' } },
  -- EXPERIMENTAL: the host's Sonar friend code (friend_code.lua).
  friend_code = { args = { force = 'boolean?' } },
  -- Replay the starter set and the host's base-piece and tool unlocks to one
  -- player or all, one batch each (unlock_replay.lua).
  unlocks = { args = { player = 'string?' } },
  -- Re-read control/settings.yaml; only verified commands run (settings.lua).
  settings = { args = {} },
}

-- A console line is one command: no separators or control characters, so a
-- request cannot chain a second command the allowlist did not name.
function M.console_line_ok(line)
  return type(line) == 'string' and #line > 0 and #line <= 128
    and not line:find('[%c;|`]')
end

local NONCE_PATTERN = '^[0-9a-f]+$'

function M.valid_nonce(id)
  return type(id) == 'string' and #id >= 16 and #id <= 64 and id:match(NONCE_PATTERN) ~= nil
end

-- Returns a new replay guard: remembers every nonce seen by this process.
function M.new_seen(initial)
  local seen, count = {}, 0
  for _, id in ipairs(initial or {}) do
    if M.valid_nonce(id) and not seen[id] then seen[id] = true; count = count + 1 end
  end
  return {
    check_and_add = function(id)
      if seen[id] then return false end
      seen[id] = true
      count = count + 1
      return true
    end,
    count = function() return count end,
  }
end

-- JSON is UTF-8 on the wire. Reject overlong encodings, surrogates, stray
-- continuation bytes and code points beyond U+10FFFF before the decoder sees
-- the request. Lua strings are bytes, so this is independent of the locale.
function M.valid_utf8(s)
  if type(s) ~= 'string' then return false end
  local i, n = 1, #s
  while i <= n do
    local a = s:byte(i)
    if a < 0x80 then i = i + 1
    elseif a >= 0xC2 and a <= 0xDF then
      local b = s:byte(i + 1); if not b or b < 0x80 or b > 0xBF then return false end; i = i + 2
    elseif a >= 0xE0 and a <= 0xEF then
      local b, c = s:byte(i + 1), s:byte(i + 2)
      if not b or not c or c < 0x80 or c > 0xBF or b < 0x80 or b > 0xBF
        or (a == 0xE0 and b < 0xA0) or (a == 0xED and b > 0x9F) then return false end
      i = i + 3
    elseif a >= 0xF0 and a <= 0xF4 then
      local b, c, d = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
      if not b or not c or not d or c < 0x80 or c > 0xBF or d < 0x80 or d > 0xBF
        or b < 0x80 or b > 0xBF or (a == 0xF0 and b < 0x90) or (a == 0xF4 and b > 0x8F) then return false end
      i = i + 4
    else return false end
  end
  return true
end

local function check_args(spec, args)
  if args == nil then args = {} end
  if type(args) ~= 'table' then return nil, 'args_not_object' end
  for k in pairs(args) do
    if spec[k] == nil then return nil, 'unknown_arg:' .. tostring(k) end
  end
  for k, want in pairs(spec) do
    local optional = want:sub(-1) == '?'
    local base = optional and want:sub(1, -2) or want
    local v = args[k]
    if v == nil then
      if not optional then return nil, 'missing_arg:' .. k end
    elseif type(v) ~= base then return nil, 'bad_arg_type:' .. k
    elseif base == 'string' and (#v == 0 or #v > 128) then return nil, 'bad_arg_length:' .. k
    end
  end
  return args
end

-- Validate one decoded command.
--   msg      decoded JSON table
--   filename the inbox file's base name, which must be "<id>.json"
--   now      unix seconds
--   enabled  set of command names enabled in config.json
--   seen     a guard from new_seen()
-- Returns cmd, args on success; nil, error_code on refusal.
function M.validate(msg, filename, now, enabled, seen)
  if type(msg) ~= 'table' then return nil, 'not_object' end
  if msg.v ~= M.VERSION then return nil, 'bad_version' end
  if not M.valid_nonce(msg.id) then return nil, 'bad_nonce' end
  if filename ~= msg.id .. '.json' then return nil, 'nonce_filename_mismatch' end
  if type(msg.ts) ~= 'number' then return nil, 'bad_timestamp' end
  if math.abs(now - msg.ts) > M.MAX_AGE_SECONDS then return nil, 'stale' end
  local spec = M.ALLOWLIST[msg.cmd]
  if type(msg.cmd) ~= 'string' or spec == nil then return nil, 'not_allowlisted' end
  if not enabled[msg.cmd] then return nil, 'disabled_by_config' end
  if not seen.check_and_add(msg.id) then return nil, 'replay' end
  local args, err = check_args(spec.args, msg.args)
  if not args then return nil, err end
  if args.command ~= nil and not M.console_line_ok(args.command) then
    return nil, 'bad_console_line'
  end
  return msg.cmd, args
end

function M.result(id, ok, data, err, game_build_id)
  return { v = M.VERSION, accepts = M.ACCEPTED_VERSIONS, id = id, ok = ok,
    data = data or {}, error = err,
    meta = { game_build_id = game_build_id or 'unknown', mod_version = M.MOD_VERSION } }
end

-- Readiness: required checks named in config, all must be true.
function M.ready(checks, required)
  local missing = {}
  for _, name in ipairs(required) do
    if checks[name] ~= true then missing[#missing + 1] = name end
  end
  return #missing == 0, missing
end

return M
