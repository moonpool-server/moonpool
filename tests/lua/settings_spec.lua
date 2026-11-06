-- Tests for mod/SN2SlotFreeHost/Scripts/settings.lua: settings.yaml parsing,
-- refusal of every key without a verified command, and the status block the
-- card reads. Plain Lua 5.4, no framework: run as
--   lua5.4 tests/lua/settings_spec.lua   (from the repository root)
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local settings = require('settings')

local failures, ran = 0, 0
local function check(ok, what)
  ran = ran + 1
  if not ok then
    failures = failures + 1
    print('FAIL ' .. what)
  end
end

local yaml = table.concat({
  '# server settings, shown to players',
  'time_of_day: "08:30"',
  'daylight: long   # a trailing comment',
  'weather: clear',
  'mods:',
  '  - name: AutoSwim',
  '    version: 1.2',
  '    url: https://www.nexusmods.com/subnautica2/mods/1',
  '    required: true',
  '    files:',
  '      - path: AutoSwim_P.pak',
  '  - name: No link here',
  '    url: javascript:alert(1)',
}, '\r\n')

local cfg, err = settings.parse(yaml)
check(cfg ~= nil, 'parse: ' .. tostring(err))
check(cfg.time_of_day == '08:30', 'quoted value kept: ' .. tostring(cfg.time_of_day))
check(cfg.daylight == 'long', 'trailing comment dropped: ' .. tostring(cfg.daylight))
check(cfg.weather == 'clear', 'weather read')
check(#cfg.mods == 2, 'two mods, got ' .. #cfg.mods)
check(cfg.mods[1].name == 'AutoSwim' and cfg.mods[1].version == '1.2', 'mod name and version')
check(cfg.mods[1].url == 'https://www.nexusmods.com/subnautica2/mods/1', 'mod url')
check(cfg.mods[1].path == nil, 'a nested files list stays out of the mod item')

-- Without a verified command every value is refused, none applied.
local p = settings.plan(cfg, {})
check(#p.apply == 0, 'nothing applied without a verified command')
check(#p.refused == 3, 'three refusals, got ' .. #p.refused)
for _, r in ipairs(p.refused) do
  check(r.reason == 'no verified command', r.key .. ' refused as no verified command, got ' .. r.reason)
end
check(p.mods[1].url ~= nil and p.mods[2].url == nil, 'only an https link is kept')

-- The verified commands: time_of_day as HH:MM through SetTimeOfDay, daylight as
-- frozen or normal, weather as the type's asset name; the file's "long" is out
-- of range.
local pv = settings.plan(cfg)
check(#pv.apply == 2 and pv.apply[1].key == 'time_of_day' and pv.apply[1].line == 'SetTimeOfDay 08:30',
  'time_of_day applies through SetTimeOfDay HH:MM (got ' .. tostring(pv.apply[1] and pv.apply[1].line) .. ')')
check(pv.apply[2].key == 'weather' and pv.apply[2].line == 'DA_Clear',
  'weather clear names the DA_Clear type (got ' .. tostring(pv.apply[2] and pv.apply[2].line) .. ')')
check(#pv.refused == 1, 'daylight alone refused, got ' .. #pv.refused)
for _, bad in ipairs({ '24:00', '08:60', '8', 'noon', '' }) do
  check(settings.VERIFIED.time_of_day(bad) == nil, 'time_of_day refuses ' .. bad)
end
check(settings.VERIFIED.time_of_day('7:05') == 'SetTimeOfDay 07:05', 'a single-digit hour is padded')
-- daylight: frozen holds the clock, normal lets it run; anything else is out of range
-- (the file above says "long", which is why it is refused there, not applied).
check(settings.VERIFIED.daylight('frozen') == 'FreezeTime', 'daylight frozen freezes the clock')
check(settings.VERIFIED.daylight(' Normal ') == 'UnfreezeTime', 'daylight normal lets it run, any case')
for _, bad in ipairs({ 'long', 'day', 'true', '', 'frozen; God' }) do
  check(settings.VERIFIED.daylight(bad) == nil, 'daylight refuses ' .. bad)
end
-- weather: a type name with or without its DA_ prefix; anything else is out of range
check(settings.VERIFIED.weather('DA_Misty') == 'DA_Misty', 'a full type name passes as it is')
check(settings.VERIFIED.weather(' cloudyB ') == 'DA_CloudyB', 'a bare name gets the DA_ prefix')
for _, bad in ipairs({ '', 'clear skies', 'DA_Clear; God', 'storm/A' }) do
  check(settings.VERIFIED.weather(bad) == nil, 'weather refuses ' .. bad)
end
local reasons_v = {}
for _, r in ipairs(pv.refused) do reasons_v[r.key] = r.reason end
check(reasons_v.daylight == 'value out of range', 'daylight long is out of range')

-- Unknown keys are refused by name, never applied or dropped silently; a known
-- key with no verified command is refused as such.
local p2 = settings.plan(assert(settings.parse('fog: thick\nweather: rain\n')),
  { time_of_day = settings.VERIFIED.time_of_day })
local reasons = {}
for _, r in ipairs(p2.refused) do reasons[r.key] = r.reason end
check(reasons.fog == 'unknown setting', 'unknown key refused')
check(reasons.weather == 'no verified command', 'unverified key refused')

-- With a verified command (as the operator would add after a live proof),
-- only that key is applied; the others stay refused.
local fake = { time_of_day = function(v)
  local h = tonumber(v:match('^(%d+)'))
  if h and h < 24 then return 'SetTimeOfDay ' .. h end
end }
local p3 = settings.plan(cfg, fake)
check(#p3.apply == 1 and p3.apply[1].line == 'SetTimeOfDay 8', 'verified key applied once')
check(#p3.refused == 2, 'the others still refused')
local p4 = settings.plan(assert(settings.parse('time_of_day: 99\n')), fake)
check(p4.refused[1].reason == 'value out of range', 'bad value refused, not guessed')

-- The status block never carries a nil: the older rows, and the per-key
-- block with its fields, a missing readback as JSON null.
local json = require('json')
local s = settings.status_block(p3, settings.submission(p3), {}, '2026-11-01T21:00:00Z')
check(#s.values == 3, 'status block has every value')
for _, v in ipairs(s.values) do check(v.value ~= nil and v.applied ~= nil, 'no nil in ' .. v.key) end
for _, k in ipairs(settings.KEYS) do
  local row = s[k]
  check(row ~= nil, 'per-key block has ' .. k)
  for _, f in ipairs({ 'desired', 'submitted', 'observed', 'verified_at' }) do
    check(row ~= nil and row[f] ~= nil, 'no nil ' .. f .. ' in ' .. k)
  end
end
check(s.time_of_day.submitted == true and s.time_of_day.observed == json.null
  and s.time_of_day.verified_at == json.null and s.time_of_day.drifted == nil,
  'a submitted key with no readback yet: observed and verified_at null, no drift field')
check(s.daylight.submitted == false and s.daylight.reason == 'no verified command'
  and s.daylight.desired == 'long' and s.daylight.drifted == false,
  'a refused key carries its reason and the value as written')
check(s.weather.submitted == false and s.weather.desired == 'DA_Clear',
  'desired is the compared form even when refused')

-- The match rule: exact for daylight and weather; a clock reading counts
-- within 30 game minutes after the desired time, the day wrapping.
check(settings.matches('weather', 'DA_Clear', 'DA_Clear') and not settings.matches('weather', 'DA_Clear', 'DA_Misty'),
  'weather matches by asset name')
check(settings.matches('daylight', 'frozen', 'frozen') and not settings.matches('daylight', 'frozen', 'normal'),
  'daylight matches by word')
check(not settings.matches('weather', 'DA_Clear', nil), 'no readback matches nothing')
check(settings.matches('time_of_day', '08:30', '08:30') and settings.matches('time_of_day', '08:30', '09:00'),
  'a clock within 30 minutes after the desired time counts')
check(not settings.matches('time_of_day', '08:30', '09:01') and not settings.matches('time_of_day', '08:30', '08:29'),
  'a clock past the window or before the time does not')
check(settings.matches('time_of_day', '23:50', '00:10'), 'the window wraps midnight')
check(not settings.matches('time_of_day', '08:30', 'noon'), 'a clock that is not HH:MM does not match')

-- Observation over time on the verified plan (time_of_day and weather ran,
-- daylight refused): verified_at is the first observation after the
-- submission that showed the value and keeps it; weather and the clock
-- carry no drift field; a new submission starts over.
local track = settings.submission(pv)
local b1 = settings.observe(track, { time_of_day = '07:00', weather = 'DA_CloudyB', daylight = 'normal' }, 't1')
check(b1.time_of_day.verified_at == json.null and b1.weather.verified_at == json.null
  and b1.weather.observed == 'DA_CloudyB', 'not yet shown: no verified_at, the readback shown')
local b2 = settings.observe(track, { time_of_day = '08:40', weather = 'DA_Clear', daylight = 'normal' }, 't2')
check(b2.time_of_day.verified_at == 't2' and b2.weather.verified_at == 't2', 'verified_at is the first showing')
check(b2.daylight.verified_at == json.null and b2.daylight.observed == 'normal' and b2.daylight.drifted == false,
  'a refused key is never verified, its readback still shown')
local b3 = settings.observe(track, { time_of_day = '09:30', weather = 'DA_Misty', daylight = 'normal' }, 't3')
check(b3.time_of_day.verified_at == 't2' and b3.weather.verified_at == 't2' and b3.weather.observed == 'DA_Misty',
  'a value that showed and moved on keeps its verified_at, the readback shown')
check(b3.time_of_day.drifted == nil and b3.weather.drifted == nil, 'the clock and the weather carry no drift field')
local b4 = settings.observe(track, { time_of_day = '09:40' }, 't4')
check(b4.weather.observed == json.null and b4.weather.verified_at == 't2', 'a readback that goes missing is null')
local fresh = settings.observe(settings.submission(pv), { weather = 'DA_Misty' }, 't6')
check(fresh.weather.verified_at == json.null, 'a new submission starts with no verified_at')
local look = settings.submission(pv)
check(settings.observe(look, { weather = 'DA_Clear' }).weather.verified_at == json.null
  and settings.observe(look, { weather = 'DA_Clear' }, 't8').weather.verified_at == 't8',
  'a look with no time marks nothing; the next timed observation does')
check(settings.observe({}, { weather = 'DA_Clear' }, 't7').weather == nil, 'an unconfigured key has no row')

-- Daylight drift: a clock verified as held and then seen running. `normal`
-- never drifts (the idle freeze may hold an empty server's clock).
local held = settings.plan(assert(settings.parse('daylight: frozen\n')))
local ht = settings.submission(held)
local h1 = settings.observe(ht, { daylight = 'normal' }, 'h1')
check(h1.daylight.drifted == false and h1.daylight.verified_at == json.null, 'not held yet is not drift')
local h2 = settings.observe(ht, { daylight = 'frozen' }, 'h2')
check(h2.daylight.verified_at == 'h2' and h2.daylight.drifted == false, 'held: verified, no drift')
local h3 = settings.observe(ht, { daylight = 'normal' }, 'h3')
check(h3.daylight.drifted == true and h3.daylight.verified_at == 'h2', 'a held clock seen running is drift')
local nt = settings.submission(settings.plan(assert(settings.parse('daylight: normal\n'))))
settings.observe(nt, { daylight = 'normal' }, 'n1')
check(settings.observe(nt, { daylight = 'frozen' }, 'n2').daylight.drifted == false, 'normal never drifts')

-- Malformed input is refused with the line number.
local bad, e = settings.parse('weather clear\n')
check(bad == nil and e:match('line 1'), 'malformed line named')
local none = settings.parse('')
check(none and #none.mods == 0, 'empty file is no settings')

print(ran .. ' checks, ' .. failures .. ' failures')
os.exit(failures == 0 and 0 or 1)
