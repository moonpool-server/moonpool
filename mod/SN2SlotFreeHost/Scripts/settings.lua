-- settings.lua: the operator's settings.yaml, parsed and planned; pure Lua, no game calls.
-- A setting runs only through a command in VERIFIED; every other one is refused by name.
local json = require('json')

local M = {}

M.KEYS = { 'time_of_day', 'daylight', 'weather' }

-- The clock keeps running, so a reading this many game minutes after the desired time still counts.
M.CLOCK_WINDOW_MINUTES = 30

-- key -> the value in the form the readback is compared in, or nil when it is out of range.
M.NORMAL = {
  time_of_day = function(v)
    local h, m = tostring(v):match('^%s*(%d%d?):(%d%d)%s*$')
    h, m = tonumber(h), tonumber(m)
    if not h or not m or h > 23 or m > 59 then return nil end
    return string.format('%02d:%02d', h, m)
  end,
  daylight = function(v)
    local word = tostring(v):lower():match('^%s*(%a+)%s*$')
    if word == 'frozen' or word == 'normal' then return word end
    return nil
  end,
  -- `clear` and `DA_Clear` both name the DA_Clear weather type.
  weather = function(v)
    local word = tostring(v):match('^%s*([%w_]+)%s*$')
    if not word then return nil end
    if word:sub(1, 3) == 'DA_' then return word end
    return 'DA_' .. word:sub(1, 1):upper() .. word:sub(2)
  end,
}

-- key -> the one console line, or nil when the value is out of range.
M.VERIFIED = {
  time_of_day = function(v)
    local t = M.NORMAL.time_of_day(v)
    return t and 'SetTimeOfDay ' .. t
  end,
  daylight = function(v)
    local word = M.NORMAL.daylight(v)
    if word == 'frozen' then return 'FreezeTime' end
    if word == 'normal' then return 'UnfreezeTime' end
    return nil
  end,
  -- The type's asset name, for the weather component: the console's weather commands move nothing.
  weather = M.NORMAL.weather,
}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

local function scalar(v)
  v = trim(v)
  local q = v:sub(1, 1)
  if (q == '"' or q == "'") and v:sub(-1) == q and #v >= 2 then return v:sub(2, -2) end
  v = trim((v:gsub('%s+#.*$', '')))
  return v
end

-- Top-level `key: value` lines only. An older file may still carry a `mods:` list; plugins.yaml
-- lists mods now, so that block is skipped. Returns the table, or nil and the line at fault.
function M.parse(text)
  if type(text) ~= 'string' then return nil, 'no settings file' end
  local out, in_mods, n = {}, false, 0
  for raw in (text .. '\n'):gmatch('([^\n]*)\n') do
    n = n + 1
    local line = raw:gsub('\r$', '')
    if not line:match('^%s*$') and not line:match('^%s*#') then
      if line:match('^%s') then
        if not in_mods then return nil, 'line ' .. n .. ': unexpected indent' end
      else
        local k, v = line:match('^([%w_]+):%s*(.*)$')
        if not k then return nil, 'line ' .. n .. ': expected key: value' end
        in_mods = k == 'mods'
        if not in_mods then out[k] = scalar(v) end
      end
    end
  end
  return out
end

-- Each known key with its console line or its refusal; unknown keys refused by name.
function M.plan(cfg, verified)
  verified = verified or M.VERIFIED
  local p = { values = {}, apply = {}, refused = {} }
  local known = {}
  for _, k in ipairs(M.KEYS) do
    known[k] = true
    local v = cfg[k]
    if v ~= nil and v ~= '' then
      -- A value out of range is carried as written, so the card shows what was asked.
      local desired = M.NORMAL[k](v) or tostring(v)
      p.values[#p.values + 1] = { key = k, value = v, desired = desired }
      local f = verified[k]
      local line = f and f(v)
      if line then
        p.apply[#p.apply + 1] = { key = k, value = v, desired = desired, line = line }
      else
        p.refused[#p.refused + 1] = { key = k, value = v, desired = desired,
          reason = f and 'value out of range' or 'no verified command' }
      end
    end
  end
  local extra = {}
  for k in pairs(cfg) do
    if not known[k] then extra[#extra + 1] = k end
  end
  table.sort(extra)
  for _, k in ipairs(extra) do
    p.refused[#p.refused + 1] = { key = k, value = cfg[k], reason = 'unknown setting' }
  end
  return p
end

local function minutes(hhmm)
  local h, m = tostring(hhmm):match('^(%d%d):(%d%d)$')
  if not h then return nil end
  return tonumber(h) * 60 + tonumber(m)
end
function M.matches(key, desired, observed)
  if desired == nil or observed == nil then return false end
  if key == 'time_of_day' then
    local d, o = minutes(desired), minutes(observed)
    if not d or not o then return false end
    return (o - d) % (24 * 60) <= M.CLOCK_WINDOW_MINUTES
  end
  return desired == observed
end

-- One entry per configured key: what was asked and whether it ran. `verified_at` starts empty.
function M.submission(p)
  local t = {}
  for _, a in ipairs(p.apply) do t[a.key] = { desired = a.desired, submitted = true } end
  for _, r in ipairs(p.refused) do
    if r.desired then t[r.key] = { desired = r.desired, submitted = false, reason = r.reason } end
  end
  return t
end

-- The per-key block for one look at the readbacks; with `now` it marks `verified_at` the first
-- time the value shows. The weather cycles and the clock runs, so only a lost hold is drift.
function M.observe(track, obs, now)
  local block = {}
  for _, k in ipairs(M.KEYS) do
    local t = track[k]
    if t then
      local seen = obs[k]
      if now and t.submitted and not t.verified_at and M.matches(k, t.desired, seen) then t.verified_at = now end
      block[k] = {
        desired = t.desired,
        submitted = t.submitted,
        observed = seen == nil and json.null or seen,
        verified_at = t.verified_at or json.null,
      }
      if t.reason then block[k].reason = t.reason end
      if k == 'daylight' then
        block[k].drifted = (t.verified_at ~= nil and t.desired == 'frozen' and seen ~= 'frozen') or false
      end
    end
  end
  return block
end

-- status.json's `settings`: the per-key rows plus `values`, what ran and what was refused.
function M.status_block(p, track, obs, now)
  local s = M.observe(track, obs or {}, now)
  s.values = {}
  for _, a in ipairs(p.apply) do s.values[#s.values + 1] = { key = a.key, value = a.value, applied = true } end
  for _, r in ipairs(p.refused) do
    s.values[#s.values + 1] = { key = r.key, value = r.value, applied = false, reason = r.reason }
  end
  return s
end

return M
