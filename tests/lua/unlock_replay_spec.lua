-- Fake-game tests for mod/SN2SlotFreeHost/Scripts/unlock_replay.lua (the
-- unlock replay on a pruned host: starter set, base pieces, scanned tools).
-- Plain Lua 5.4, no framework:
--   lua5.4 tests/lua/unlock_replay_spec.lua   (from the repository root)
-- Exits 1 on the first failure; bats runs it in tests/control-protocol.bats.
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local ur = require('unlock_replay')

local failures, ran = 0, 0
local function eq(got, want, what)
  ran = ran + 1
  if got ~= want then
    failures = failures + 1
    print(string.format('FAIL %s: got [%s] want [%s]', what, tostring(got), tostring(want)))
  end
end

-- A fake game: records each BATCH per player (one game.send call = one
-- command file run as that player) and each log line; the asset index holds
-- only the names in `assets`.
local function fake(assets)
  local g = { batches = {}, logs = {}, assets = assets or {} }
  g.send = function(player, lines)
    assert(type(lines) == 'table', 'send takes a list of lines')
    g.batches[player] = g.batches[player] or {}
    table.insert(g.batches[player], lines)
  end
  g.exists = function(name) return g.assets[name] == true end
  g.log = function(l) table.insert(g.logs, l) end
  -- Every line the player got, across batches.
  g.sent = function(player)
    local out = {}
    for _, b in ipairs(g.batches[player] or {}) do
      for _, l in ipairs(b) do out[#out + 1] = l end
    end
    return out
  end
  return g
end
local function joined(t) return table.concat(t or {}, '|') end
local function has(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
local function count(t, v) local n = 0 for _, x in ipairs(t) do if x == v then n = n + 1 end end return n end

-- Goal and scan-data names map to keys; anything else maps to nothing.
eq(ur.piece_of('DA_BasePiece_BatteryTerminal_StoryGoal'), 'BatteryTerminal', 'story goal name')
eq(ur.piece_of('/Game/Goals/DA_BasePiece_Spotlight_StoryGoal.DA_BasePiece_Spotlight_StoryGoal'),
  'Spotlight', 'full object path')
eq(ur.piece_of('DA_BasePiece_ScannerStationLR_ScanData'), 'ScannerStation', 'LR scan data')
eq(ur.piece_of('DA_BasePiece_ScannerStationSR_ScanData'), 'ScannerStation', 'SR scan data')
eq(ur.piece_of('DA_BasePiece_CeilingLightSmall'), 'CeilingLightSmall', 'bare goal')
eq(ur.piece_of('DA_Tools_Flashlight_StoryGoal'), 'Tools_Flashlight', 'tool goal name')
eq(ur.piece_of('/Game/Goals/DA_Tools_AirBladder_StoryGoal.DA_Tools_AirBladder_StoryGoal'),
  'Tools_AirBladder', 'tool full object path')
eq(ur.piece_of('DA_Tools__StoryGoal'), nil, 'empty tool name')
eq(ur.piece_of('DA_Lifepod_Ascent_StoryGoal'), nil, 'not a base piece or tool')
eq(ur.piece_of('DA_BasicBasebuilding_StoryGoal'), nil, 'the starter goal is not a key: it is always sent')
eq(ur.piece_of(nil), nil, 'nil')

-- BASE PIECE: the proven forms for the Battery Terminal, in order, one batch per player.
local st = ur.new('Slot1')
local g = fake()
local line = '[2026.11.01-05.12.03:120][  0]LogStoryGoals: Unlocked story goal DA_BasePiece_BatteryTerminal_StoryGoal'
local piece = ur.line(st, line)
eq(piece, 'BatteryTerminal', 'host log line gives the piece')
ur.broadcast(g, piece, { 'SN2 Host', 'Example Diver', 'Ana' }, 'SN2 Host')
eq(joined(g.sent('Example Diver')), table.concat({
  'Unlock DA_BasicBatteryTerminal_ItemType', 'Unlock BasicBatteryTerminal',
  'Unlock DA_BasicBatteryTerminalConstructData', 'Unlock BasicBatteryTerminal_ItemType',
  'Unlock DA_BasePiece_BatteryTerminal_ScanData' }, '|'), 'battery terminal forms')
eq(#g.batches['Example Diver'], 1, 'a host unlock is one batch per player')
eq(#g.sent('Ana'), 5, 'every connected player gets them')
eq(g.batches['SN2 Host'], nil, 'never the host')
eq(g.logs[1], 'unlock BatteryTerminal sent to Example Diver: 5 forms', 'broadcast log line')
eq(ur.line(st, line), nil, 'the same goal twice is not new')

-- TOOL: a host-side DA_Tools_<X>_StoryGoal sends ItemType, Recipe, ScanData;
-- the extra forms only when they exist by name.
local tline = '[2026.11.01-06.02.11:004][  0]LogStoryGoals: Unlocked story goal DA_Tools_Flashlight_StoryGoal'
local tool = ur.line(st, tline)
eq(tool, 'Tools_Flashlight', 'tool log line gives the tool key')
eq(ur.set_of(tool), 'tools', 'tool key is in the tools set')
eq(ur.set_of('Spotlight'), 'pieces', 'base piece key is in the pieces set')
local gt = fake({ Flashlight = true })
ur.broadcast(gt, tool, { 'Ana' }, 'SN2 Host')
eq(joined(gt.sent('Ana')), 'Unlock DA_Flashlight_ItemType|Unlock DA_FlashlightRecipe|' ..
  'Unlock DA_Flashlight_ScanData|Unlock Flashlight', 'flashlight forms, bare name found by lookup')
eq(#ur.forms('Tools_Beacon'), 3, 'tool with nothing found: the three forms')
eq(ur.forms('Tools_Beacon', function() error('lookup threw') end)[3], 'DA_Beacon_ScanData',
  'a lookup that throws adds nothing and breaks nothing')
for _, t in ipairs({ 'Beacon', 'Flare', 'Flashlight', 'AirBladder', 'Wakemaker', 'SonicResonator',
  'DeployableLocker', 'Fins', 'ImprovedFins' }) do
  eq(ur.forms('Tools_' .. t)[1], 'DA_' .. t .. '_ItemType', t .. ' item type first')
end

-- STARTER: the solar panel's proven forms, plus V2/Medium variants by name.
local sp = ur.forms('SolarPanel', fake({ DA_SolarPanelV2_ItemType = true,
  DA_SolarPanel_Medium_ConstructData = true }).exists)
eq(joined(sp), table.concat({ 'DA_SolarPanel_ItemType', 'DA_SolarPanelRecipe',
  'DA_SolarPanelConstructData', 'DA_BasePiece_SolarPanel_ScanData', 'SolarPanel',
  'DA_SolarPanelV2_ItemType', 'DA_SolarPanel_Medium_ConstructData' }, '|'),
  'solar panel forms with the variants that exist')
eq(#ur.forms('SolarPanel'), 5, 'solar panel without lookup: the five proven forms')
eq(joined(ur.forms('Foundation')), 'Foundation|DA_BasePiece_Foundation_ScanData', 'foundation: name and scan data')
eq(#ur.forms('Ladder', fake({ DA_Ladder_ItemType = true, DA_LadderRecipe = true }).exists), 4,
  'ladder: two forms + two found')
for _, s in ipairs({ 'SolarPanel', 'Room', 'Corridor', 'Window', 'Foundation', 'Ladder', 'Hatch',
  'PowerStorage', 'Glass' }) do
  eq(has(ur.STARTER, s), true, s .. ' is in the starter set')
end

-- Every proven table entry is sent whole.
for name, forms in pairs(ur.FORMS) do
  eq(joined(ur.forms(name)), joined(forms), name .. ' forms sent whole')
end
eq(#ur.forms('ScannerStation'), 7, 'scanner station: seven forms')
eq(#ur.forms('Biolab'), 8, 'biolab: eight forms')

-- Names-only lookup adds a candidate only when the asset exists by name.
local g2 = fake({ DA_Processor_ItemType = true, DA_Corridor_ItemType = false })
local pf = ur.forms('Processor', g2.exists)
eq(pf[#pf], 'DA_Processor_ItemType', 'processor item type added when it exists')
eq(#pf, 5, 'processor: four proven + one found')
eq(#ur.forms('Corridor', g2.exists), 2, 'corridor: just the two when nothing is found')
eq(joined(ur.forms('Processor', function() return true end)):find('DA_ProcessorRecipe|.*DA_ProcessorRecipe'),
  nil, 'no duplicate form')
eq(#ur.forms('Locker'), 2, 'unknown piece: bare name and scan data')

-- JOIN: one batch holding the starter set, then the base pieces and tools the
-- host has; one log line with the counts per set.
local starter_lines = #ur.lines(ur.STARTER)
eq(starter_lines, 22, 'starter set without lookups: 22 lines (solar 5, hatch 3, seven pieces x 2)')
local st3 = ur.new('Slot1', { 'BatteryTerminal', 'Spotlight', 'Tools_Flashlight' })
local g3 = fake()
local first = ur.joins(st3, g3, { 'SN2 Host', 'Example Diver' }, 'SN2 Host')
eq(joined(first), 'Example Diver', 'the joiner is replayed to')
eq(#g3.batches['Example Diver'], 1, 'the whole replay is ONE batch')
local got = g3.sent('Example Diver')
eq(#got, starter_lines + 9 + 3, 'starter + battery terminal 5 + spotlight 4 + flashlight 3')
eq(got[1], 'Unlock DA_SolarPanel_ItemType', 'starter set first')
eq(has(got, 'Unlock DA_BasicBatteryTerminal_ItemType'), true, 'base piece in the batch')
eq(has(got, 'Unlock DA_Flashlight_ItemType'), true, 'tool in the batch')
eq(count(got, 'Unlock Hatch'), 1, 'a starter piece also unlocked on the host is sent once')
eq(g3.logs[1], 'unlocks: Example Diver has a controller; body yes',
  'the joiner is named once when first seen, with whether it has a body')
eq(g3.logs[2], string.format('unlocks replayed to Example Diver: %d (starter %d, '
  .. 'habitat builder bundle 0, base pieces 9, tools 3, scans 0)',
  starter_lines + 12, starter_lines), 'one log line with the counts')
eq(#ur.joins(st3, g3, { 'SN2 Host', 'Example Diver' }, 'SN2 Host'), 0, 'no second replay while present')
ur.joins(st3, g3, { 'SN2 Host' }, 'SN2 Host')
eq(#ur.joins(st3, g3, { 'SN2 Host', 'Example Diver' }, 'SN2 Host'), 0,
  'one batch per joiner per session: a rejoin does not replay')

-- A joiner gets the starter set even when the host has unlocked nothing.
local g4 = fake()
ur.joins(ur.new('Slot1'), g4, { 'Ana' }, 'SN2 Host')
eq(#g4.sent('Ana'), starter_lines, 'starter set on join with an empty host set')
eq(g4.logs[2], string.format('unlocks replayed to Ana: %d (starter %d, '
  .. 'habitat builder bundle 0, base pieces 0, tools 0, scans 0)',
  starter_lines, starter_lines), 'empty host set still logs the starter count')

-- moonpool unlocks replay by hand: the same single batch.
local g5 = fake()
ur.replay(st3, g5, 'Ana')
eq(#g5.batches['Ana'], 1, 'a hand replay is one batch')
eq(#g5.sent('Ana'), starter_lines + 12, 'a hand replay covers all three sets')

-- HABITAT BUILDER BUNDLE: its own named group, keyed on the host's
-- DA_Tools_HabitatBuilder_StoryGoal (the name confirmed in the asset index).
local bundle = ur.bundle_forms()
for _, n in ipairs({ 'DA_Fabricator_ItemType', 'DA_FabricatorRecipe', 'DA_FabricatorConstructData',
  'DA_BasePiece_Fabricator_ScanData', 'DA_FabricatorPillar_ItemType', 'DA_WallLocker_ItemType',
  'DA_FloatingLocker_Carryable_ItemType', 'DA_BasePiece_NoATerminal_ScanData',
  'DA_BasePiece_CeilingLightSmall_ScanData', 'DA_CeilingLight_Rect_A_ItemType',
  'DA_BaseSignal_ItemType', 'DA_BaseSignal_Recipe', 'DA_BaseSignalConstructData',
  'DA_Radio_ItemType', 'DA_HatchRecipe', 'DA_SolarPanel_ItemType', 'DA_BasePiece_Corridor_ScanData',
  'DA_BasePiece_Window_ScanData', 'DA_Builder_ItemType' }) do
  eq(has(bundle, n), true, n .. ' is in the habitat builder bundle')
end
local seen_b = {}
for _, n in ipairs(bundle) do eq(seen_b[n], nil, 'bundle form once: ' .. n); seen_b[n] = true end
eq(#ur.BUNDLE, 13, 'bundle: the builder and twelve granted pieces')
local bline = '[2026.11.01-06.27.40:311][  0]LogStoryGoals: Unlocked story goal DA_Tools_HabitatBuilder_StoryGoal'
local stb = ur.new('Slot1')
local bkey = ur.line(stb, bline)
eq(bkey, ur.BUNDLE_GOAL, 'the habitat builder goal gives the bundle key')
eq(ur.set_of(bkey), 'bundle', 'bundle key is in its own set')
eq(joined(ur.forms(bkey)), joined(bundle), 'the bundle key sends exactly the bundle forms')
local gb = fake()
ur.broadcast(gb, bkey, { 'SN2 Host', 'Example Diver' }, 'SN2 Host')
eq(#gb.batches['Example Diver'], 1, 'the bundle on a host unlock is one batch')
eq(#gb.sent('Example Diver'), #bundle, 'every bundle form sent on the host unlock')
eq(gb.logs[1], string.format('unlock habitat builder bundle sent to Example Diver: %d forms', #bundle),
  'bundle broadcast log names the group')
-- On join: the bundle rides in the same single batch, shared forms once.
local gj = fake()
ur.joins(stb, gj, { 'SN2 Host', 'Ana' }, 'SN2 Host')
eq(#gj.batches['Ana'], 1, 'join with the bundle is still ONE batch')
local gotb = gj.sent('Ana')
eq(has(gotb, 'Unlock DA_Fabricator_ItemType'), true, 'bundle replayed on join')
eq(count(gotb, 'Unlock DA_SolarPanel_ItemType'), 1, 'a form in both starter and bundle is sent once')
local bundle_only = #ur.lines({ bkey }) - #ur.lines({ 'SolarPanel', 'Corridor', 'Window', 'Hatch' })
eq(#gotb, starter_lines + bundle_only, 'join count: starter plus the bundle forms the starter lacks')
eq(gj.logs[2], string.format(
  'unlocks replayed to Ana: %d (starter %d, habitat builder bundle %d, base pieces 0, tools 0, scans 0)',
  starter_lines + bundle_only, starter_lines, bundle_only), 'join log line counts the bundle')
-- Without the host's goal, a joiner gets no bundle-only form.
local gn = fake()
ur.joins(ur.new('Slot1'), gn, { 'Ana' }, 'SN2 Host')
eq(has(gn.sent('Ana'), 'Unlock DA_Fabricator_ItemType'), false, 'no bundle before the host unlocks it')
-- The bundle key persists across a restart of the same save.
eq(joined(ur.seed('Slot1', { unlocks = ur.snapshot(stb) }).pieces), ur.BUNDLE_GOAL,
  'bundle key survives in status.json')

-- status.json: the set survives a restart for the same save only.
local snap = ur.snapshot(st3)
eq(joined(ur.seed('Slot1', { unlocks = snap }).pieces), 'BatteryTerminal|Spotlight|Tools_Flashlight',
  'same save seeds pieces and tools')
eq(#ur.seed('Slot2', { unlocks = snap }).pieces, 0, 'another save does not')
eq(#ur.seed('Slot1', nil).pieces, 0, 'no previous status')

-- SCANS: recorded batch. The fake asset index holds every name replayed by
-- hand, lookups without case as FName does, returning the game's spelling.
local F = dofile('tests/lua/scan_batch_fixture.lua')
local lower = {}
for _, it in pairs(F) do for _, n in ipairs(it.names) do lower[n:lower()] = n end end
local function scan_game(extra)
  local sgame = fake()
  sgame.exists = function(n) return lower[n:lower()] or (extra and extra[n]) or false end
  sgame.scan_assets = function(d) return F[d] and F[d].scans or {} end
  return sgame
end
-- Hand-batch names that are a DIFFERENT item than the one scanned (salvage,
-- scrap, a second trash can); the scan rightly does not grant them.
local NOT_THIS_SCAN = {
  DA_Salvage_Biobed_01_ItemType = true,
  DA_Scrap_HydroElectricTurbine_Deconstruct_ConstructData = true,
  DA_Scrap_HydroElectricTurbine_Deconstruct_Recipe = true,
  DA_Scrap_HydroElectricTurbine_Deconstructable_ItemType = true,
  DA_AxumTrashcanRecipe = true, DA_AxumTrashcan_ItemType = true,
}
local sg = scan_game()
local st2 = ur.new('Slot1')
for display, it in pairs(F) do
  local lines = ur.scan_forms(st2, sg, display)
  local have = {}
  for _, l in ipairs(lines) do have[l:match('%S+$')] = l end
  if #it.scans > 0 and display ~= 'Display Tank' then
    eq(have[it.scans[1]], 'Unlock ' .. it.scans[1], display .. ': the ScanData itself')
  end
  for _, n in ipairs(it.names) do
    if (n:match('_ItemType$') or n:match('Recipe$') or n:match('ConstructData$')) and not NOT_THIS_SCAN[n] then
      eq(have[n], 'Unlock ' .. n, display .. ': ' .. n)
    end
  end
  for _, l in ipairs(lines) do
    eq(l:match('^Unlock ') ~= nil or l:match('^UnlockStoryGoal ') ~= nil, true, display .. ': a console line: ' .. l)
  end
end
-- Both word orders: DiningChair_ScanData -> ChairDining_Recipe.
local dc = joined(ur.scan_forms(st2, sg, 'Dining Chair'))
eq(dc:find('Unlock DA_ChairDiningRecipe', 1, true) ~= nil
  or dc:find('Unlock DA_ChairDining_Recipe', 1, true) ~= nil, true, 'dining chair recipe, other order')
-- The game's own spelling: Flashlight scan -> DA_FlashLight_ItemType.
eq(joined(ur.scan_forms(st2, sg, 'Flashlight')):find('Unlock DA_FlashLight_ItemType', 1, true) ~= nil,
  true, 'flashlight item in the game spelling')
-- A display name that maps only to a scan with no item sibling sends nothing.
eq(#ur.scan_forms(st2, sg, 'Display Tank'), 0, 'display tank: no recipe, nothing')
-- A story goal of that base is unlocked where one exists.
local gsg = scan_game({ DA_BasePiece_Stool_StoryGoal = true })
local stool = joined(ur.scan_forms(ur.new('Slot1'), gsg, 'Stool'))
eq(stool:find('UnlockStoryGoal DA_BasePiece_Stool_StoryGoal', 1, true) ~= nil, true, 'stool story goal')
-- Creature, flora, raw resource: no item sibling, nothing at all.
local cg = scan_game()
cg.scan_assets = function(d) return ({ Peeper = { 'DA_Peeper_ScanData' },
  ['Table Coral'] = { 'DA_TableCoral_ScanData' }, Titanium = { 'DA_Titanium_ScanData' } })[d] or {} end
for _, d in ipairs({ 'Peeper', 'Table Coral', 'Titanium' }) do
  eq(#ur.scan_forms(ur.new('Slot1'), cg, d), 0, d .. ': nothing sent')
end

-- The live path: the log line, a broadcast to every present non-host player,
-- the duplicate ignored, the joiner's single batch, the status round trip.
eq(ur.scan_of('[2026.11.01-06.41.07:123][ 12]LogScanner: Dining Table has completed scan'),
  'Dining Table', 'scan line parsed')
eq(ur.scan_of('LogScanner: Dining Table started scan'), nil, 'other scanner line ignored')
local lg = scan_game()
local ls = ur.new('Slot1')
local d = ur.scan(ls, 'LogScanner: Dining Table has completed scan')
eq(d, 'Dining Table', 'new scan')
local to = ur.scan_broadcast(ls, lg, d, { 'SN2 Host', 'Ana', 'Ben' }, 'SN2 Host')
eq(joined(to), 'Ana|Ben', 'sent to present players, not the host')
eq(#(lg.batches['SN2 Host'] or {}), 0, 'host gets nothing')
eq(#lg.batches.Ana, 1, 'one batch per player')
eq(joined(lg.batches.Ana[1]):find('Unlock DA_DiningTable', 1, true) ~= nil, true, 'table forms sent')
eq(ur.scan(ls, 'LogScanner: Dining Table has completed scan'), nil, 'a repeated scan is not new')
eq(lg.logs[#lg.logs], 'scan Dining Table sent to Ben: 4 lines', 'one log line per player')
ur.scan(ls, 'LogScanner: Peeper has completed scan')
ur.scan_broadcast(ls, lg, 'Peeper', { 'Ana' }, 'SN2 Host')
eq(lg.logs[#lg.logs], 'scan Peeper: no recipe to share', 'nothing-to-share logged')
local before = #(lg.batches.Cleo or {})
ur.replay(ls, lg, 'Cleo')
eq(#lg.batches.Cleo - before, 1, 'joiner: starter, sets and scans in ONE batch')
eq(joined(lg.batches.Cleo[1]):find('Unlock DA_DiningTable', 1, true) ~= nil, true, 'joiner gets the scan')
eq(lg.logs[#lg.logs]:match('scans (%d+)%)$'), '4', 'replay line counts the scans')
local rs = ur.seed('Slot1', { unlocks = ur.snapshot(ls) })
eq(joined(rs.scans), 'Dining Table|Peeper', 'scans survive a restart through status.json')
eq(#ur.seed('Slot2', { unlocks = ur.snapshot(ls) }).scans, 0, 'not into another save')

-- PRE-CONTROL ORDER AND PACING on a fake game with a clock. The joiner has no
-- body at first (loading), then a body (pawn possessed, cinematic); control
-- is given at 10 s. The batch must go out 2 s after the first body, every
-- line before control, 50 ms apart, once per joiner per session.
local clock, events = 0, {}
local body = { Dana = false }
local gp = {
  now = function() return clock end,
  has_body = function(n) return body[n] end,
  exists = function() return false end,
  log = function() end,
  send = function(player, lines, interval)
    for _, item in ipairs(ur.schedule(lines, interval)) do
      events[#events + 1] = { t = clock + item.at, what = 'unlock', who = player, line = item.line }
    end
  end,
}
local CONTROL_AT = 10000
local spc = ur.new('Slot1')
ur.interval = ur.interval_ms(nil)
eq(ur.interval, 50, 'interval defaults to 50 ms')
eq(ur.interval_ms('120'), 120, 'interval is a setting')
eq(ur.interval_ms('3'), 10, 'interval clamps low')
eq(ur.interval_ms('99999'), 2000, 'interval clamps high')
eq(ur.interval_ms('fast'), 50, 'a bad value falls back to 50')
local sent_at, batches = nil, 0
for t = 0, 30000, 1000 do
  clock = t
  if t == 3000 then body.Dana = true end
  if t == CONTROL_AT then events[#events + 1] = { t = t, what = 'control', who = 'Dana' } end
  if #ur.joins(spc, gp, { 'SN2 Host', 'Dana' }, 'SN2 Host') > 0 then
    batches = batches + 1
    sent_at = sent_at or t
  end
end
eq(batches, 1, 'one batch for Dana over 30 s of polls')
eq(sent_at, 5000, 'batch goes out 2 s after the joiner first has a body')
table.sort(events, function(a, b) return a.t < b.t end)
local unlocks_seen, last_unlock_t, control_t, gaps_ok = 0, nil, nil, true
for _, e in ipairs(events) do
  if e.what == 'unlock' then
    if last_unlock_t and e.t - last_unlock_t ~= 50 then gaps_ok = false end
    last_unlock_t = e.t
    unlocks_seen = unlocks_seen + 1
  else
    control_t = e.t
  end
end
eq(unlocks_seen > 0, true, 'the batch has lines')
eq(gaps_ok, true, 'lines are 50 ms apart, not a burst')
eq(last_unlock_t < control_t, true, 'the whole batch lands before control is given')
-- No body yet: nothing goes out, however long the joiner loads.
local gn2_logs = {}
local gn2 = { now = function() return 60000 end, has_body = function() return false end,
  exists = function() return false end, send = function() error('sent too early') end,
  log = function(l) gn2_logs[#gn2_logs + 1] = l end }
local stn2 = ur.new('Slot1')
eq(#ur.joins(stn2, gn2, { 'Eli' }, 'SN2 Host'), 0, 'nothing before the joiner has a body')
ur.joins(stn2, gn2, { 'Eli' }, 'SN2 Host')
eq(table.concat(gn2_logs, '|'), 'unlocks: Eli has a controller; body not yet',
  'a joiner without a body is said once, so the log shows where a silent join stops')
-- A wider interval spreads the same batch.
ur.interval = 120
local wide = {}
local gw = { exists = function() return false end, log = function() end, send = function(_, lines, iv)
  for _, item in ipairs(ur.schedule(lines, iv)) do wide[#wide + 1] = item.at end end }
ur.replay(ur.new('Slot1'), gw, 'Fay')
eq(wide[2] - wide[1], 120, 'the interval setting changes the spacing')
ur.interval = 50

print(string.format('%d tests, %d failures', ran, failures))
os.exit(failures == 0 and 0 or 1)
