-- settings.lua: the operator's settings.yaml (time_of_day, daylight, weather,
-- mods), parsed and planned. Pure Lua with no game calls, so the spec tests it
-- on a fake. A setting is applied only through a command in VERIFIED; every
-- other one is refused as "no verified command" and shown as not applied.
-- Nothing here guesses a command name: a key enters VERIFIED only
-- after the operator has run it on a host nobody plays on and logged the
-- game's reply.
local json = require('json')

local M = {}

M.KEYS = { 'time_of_day', 'daylight', 'weather' }

-- A desired clock reading counts as observed while the clock, which runs,
-- reads within this many game minutes after it.
M.CLOCK_WINDOW_MINUTES = 30

-- key -> function(value) returning the value in the one form it is compared
-- in (the status block's `desired`, matched against the readback), or nil
-- when the value is out of range. The verified console lines below are built
-- from these, so apply and verification share one rule per key.
M.NORMAL = {
  -- HH:MM, 24-hour, as the clock readback (status.json time_of_day) is written.
  time_of_day = function(v)
    local h, m = tostring(v):match('^%s*(%d%d?):(%d%d)%s*$')
    h, m = tonumber(h), tonumber(m)
    if not h or not m or h > 23 or m > 59 then return nil end
    return string.format('%02d:%02d', h, m)
  end,
  -- `frozen` or `normal`, as the clock hold reads back.
  daylight = function(v)
    local word = tostring(v):lower():match('^%s*(%a+)%s*$')
    if word == 'frozen' or word == 'normal' then return word end
    return nil
  end,
  -- The weather type's asset name (DA_Clear, DA_CloudyB, DA_Misty, DA_StormA
  -- ...; status.json weather_types lists the loaded ones): `clear` and
  -- `DA_Clear` both name DA_Clear.
  weather = function(v)
    local word = tostring(v):match('^%s*([%w_]+)%s*$')
    if not word then return nil end
    if word:sub(1, 3) == 'DA_' then return word end
    return 'DA_' .. word:sub(1, 1):upper() .. word:sub(2)
  end,
}

-- key -> function(value) returning the one console line, or nil when the
-- value is out of range. A key enters here only with a live proof: the
-- command run as the host on a host nobody plays on, and a readback that
-- followed it.
M.VERIFIED = {
  -- SetTimeOfDay HH:MM (the SN2 command class's NewTimeString form), verified
  -- status.json's time_of_day, read off the
  -- day-sequence actor, followed 12:00 and then 03:00.
  time_of_day = function(v)
    local t = M.NORMAL.time_of_day(v)
    return t and 'SetTimeOfDay ' .. t
  end,
  -- FreezeTime / UnfreezeTime, verified against the same clock:
  -- held at 17:42 for 70 s after FreezeTime, 17:42 to 18:40 in 70 s after
  -- UnfreezeTime, the game log adding and removing its FreezeTime tag.
  -- `frozen` holds the clock; `normal` lets it run (the idle freeze still
  -- holds it while nobody is in).
  daylight = function(v)
    local word = M.NORMAL.daylight(v)
    if word == 'frozen' then return 'FreezeTime' end
    if word == 'normal' then return 'UnfreezeTime' end
    return nil
  end,
  -- The type's asset name, handed to the weather sync component's own
  -- SetCurrentWeather, not the console: every console form of the name was
  -- accepted and moved nothing. Verified on the recipe host:
  -- status.json's weather went DA_CloudyB to DA_Clear and then to DA_StormA,
  -- each within 40 s of the call. A name no loaded type carries is logged
  -- and moves nothing.
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

-- A small YAML subset, which is all the file uses: top-level `key: value`,
-- and `mods:` as a list of `- name: ...` items with `key: value` lines under
-- each. Lines nested deeper inside an item (a mod's files list) are kept out
-- of the card. Returns the table, or nil and a message naming the line.
function M.parse(text)
  if type(text) ~= 'string' then return nil, 'no settings file' end
  local out = { mods = {} }
  local mods, item, item_col, in_mods, list_col = out.mods, nil, nil, false, nil
  local n = 0
  for raw in (text .. '\n'):gmatch('([^\n]*)\n') do
    n = n + 1
    local line = raw:gsub('\r$', '')
    if not line:match('^%s*$') and not line:match('^%s*#') then
      local indent = #line:match('^(%s*)')
      local body = line:sub(indent + 1)
      if indent == 0 then
        local k, v = body:match('^([%w_]+):%s*(.*)$')
        if not k then return nil, 'line ' .. n .. ': expected key: value' end
        in_mods, item, list_col = (k == 'mods'), nil, nil
        if in_mods then
          if scalar(v) ~= '' and scalar(v) ~= '[]' then return nil, 'line ' .. n .. ': mods must be a list' end
        else
          out[k] = scalar(v)
        end
      elseif in_mods then
        local rest = body:match('^%-%s+(.*)$')
        if rest and not list_col then list_col = indent end
        if rest and indent == list_col then
          item, item_col = {}, indent + 2
          mods[#mods + 1] = item
          local k, v = rest:match('^([%w_]+):%s*(.*)$')
          if not k then return nil, 'line ' .. n .. ': a mod is name: value lines' end
          item[k] = scalar(v)
        elseif item and indent == item_col then
          local k, v = body:match('^([%w_]+):%s*(.*)$')
          if not k then return nil, 'line ' .. n .. ': expected key: value' end
          if scalar(v) ~= '' then item[k] = scalar(v) end
        elseif not item or indent < item_col or (rest and indent < list_col) then
          return nil, 'line ' .. n .. ': unexpected indent under mods'
        end
      else
        return nil, 'line ' .. n .. ': unexpected indent'
      end
    end
  end
  return out
end

-- What the card and the log show: each known key with its value and either
-- the console line to run or the refusal; unknown keys refused by name; mods
-- with a name and an https link only.
function M.plan(cfg, verified)
  verified = verified or M.VERIFIED
  local p = { values = {}, apply = {}, refused = {}, mods = {} }
  local known = {}
  for _, k in ipairs(M.KEYS) do
    known[k] = true
    local v = cfg[k]
    if v ~= nil and v ~= '' then
      -- `desired` is the value in its compared form; a value out of range
      -- is carried as written, so the card can show what was asked.
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
    if k ~= 'mods' and not known[k] then extra[#extra + 1] = k end
  end
  table.sort(extra)
  for _, k in ipairs(extra) do
    p.refused[#p.refused + 1] = { key = k, value = cfg[k], reason = 'unknown setting' }
  end
  for _, m in ipairs(cfg.mods or {}) do
    local url = m.url or m.link
    if m.name and m.name ~= '' then
      local mod = { name = m.name, version = m.version }
      if url and url:match('^https://[%w%.%-]+') and not url:match('[%s%)%]]') then mod.url = url end
      p.mods[#p.mods + 1] = mod
    end
  end
  return p
end

-- Whether a readback shows the desired value. Exact for daylight and weather;
-- a clock reading counts while it is within CLOCK_WINDOW_MINUTES after the
-- desired time, because the clock keeps running after SetTimeOfDay.
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

-- The record of the latest submission, one entry per configured known key:
-- what was asked, whether its call ran (and why not), and `verified_at`,
-- empty until the readback first shows the value. A new submission starts a
-- new record, so `verified_at` never carries over from an earlier one.
function M.submission(p)
  local t = {}
  for _, a in ipairs(p.apply) do t[a.key] = { desired = a.desired, submitted = true } end
  for _, r in ipairs(p.refused) do
    if r.desired then t[r.key] = { desired = r.desired, submitted = false, reason = r.reason } end
  end
  return t
end

-- One observation of the readbacks (obs: key -> value or nil) at `now` (an
-- ISO-8601 UTC string): marks `verified_at` the first time a submitted key's
-- value shows, and returns the per-key block status.json carries, a missing
-- readback as `null`. With no `now` it is a look that marks nothing (the
-- settings answer): `verified_at` is a status write's time, never the
-- answer's. Nothing here calls a setter again: the weather cycles
-- on its own and the clock runs, so neither is called drifted. Daylight is,
-- once a clock verified as held is seen running: the hold is a state the
-- mod keeps, so losing it is news.
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

-- The block status.json carries as `settings`: one row per configured key
-- from the observation (at `now`, or a look when there is none), `mods` as
-- listed, and the older `values` list (what ran and what was refused, plain
-- values, never a nil) beside them.
function M.status_block(p, track, obs, now)
  local s = M.observe(track, obs or {}, now)
  s.values, s.mods = {}, p.mods
  for _, a in ipairs(p.apply) do s.values[#s.values + 1] = { key = a.key, value = a.value, applied = true } end
  for _, r in ipairs(p.refused) do
    s.values[#s.values + 1] = { key = r.key, value = r.value, applied = false, reason = r.reason }
  end
  return s
end

return M
