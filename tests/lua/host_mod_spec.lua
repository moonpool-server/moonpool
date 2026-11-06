-- Loads SN2SlotFreeHost's main.lua with UE4SS stubbed out: it loads, the recipe
-- additions load with it, the save picker and WORLD_NAME behave. What the mod
-- DOES on a fake game is tests/lua/host_behaviour_spec.lua.
-- Run: lua5.4 tests/lua/host_mod_spec.lua
local dir = 'mod/SN2SlotFreeHost/Scripts/'
package.path = dir .. '?.lua;' .. package.path

local prints = {}
local real_print = print
_G.print = function(...) local t = {} for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
  prints[#prints + 1] = table.concat(t, ' ') end
_G.RegisterHook = function() return 1, 1 end
_G.NotifyOnNewObject = function() end
_G.LoopAsync = function() end
_G.ExecuteWithDelay = function() end
_G.ExecuteInGameThread = function(f) f() end
_G.FindFirstOf = function() return nil end
_G.FindAllOf = function() return nil end
_G.StaticFindObject = function() return nil end
_G.RegisterConsoleCommandHandler = function() end

local env = { SN2_PLAYER_SLOTS = "8", SN2_HOST_NAME = "SN2 Host", SN2_CONTROL_WIN = os.tmpname() .. ".d" }
local real_getenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] end return real_getenv(k) end

local ok, err = pcall(dofile, dir .. 'main.lua')
_G.print = real_print
local fails = 0
local function check(c, msg)
  if c then real_print('ok   ' .. msg) else fails = fails + 1; real_print('FAIL ' .. msg) end
end

check(ok, 'main.lua loads: ' .. tostring(err))
local all = table.concat(prints, '\n')
check(all:find('Mod loaded successfully', 1, true) ~= nil, 'prints its loaded line')
check(all:find('recipe additions not loaded', 1, true) == nil, 'recipe.lua loads with it')
check(type(_G.SN2_PICK_SAVE) == 'function', 'recipe hands the Host call its save picker')
do
  local state = { bHidden = false, bActorEnableCollision = true, bReplicates = true, bIsInactive = false }
  local ps = { bReplicates = true, IsValid = function() return true end }
  local pawn = setmetatable({ PlayerState = ps, IsValid = function() return true end }, {
    __index = function(_, k) return state[k] end,
    __newindex = function(_, k, v) state[k] = v end,
  })
  local looked_up
  _G.StaticFindObject = function(path) looked_up = path; return pawn end
  local before = #prints
  _G.print = function(...) local t = {} for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
    prints[#prints + 1] = table.concat(t, ' ') end
  _G.SN2_CHECK_HOST_BODY('/Game/Fake.HostPawn')
  check(looked_up == '/Game/Fake.HostPawn', 'status pass re-finds the retained host pawn path')
  check(state.bHidden and not state.bActorEnableCollision and not state.bReplicates,
    'a visible host pawn is hidden, non-solid and non-replicating again')
  check(not ps.bReplicates and ps.bIsInactive, 'the host pawn state is suppressed again')
  check(#prints == before + 1 and prints[#prints]:find('host body visible again', 1, true) ~= nil,
    'a re-hide is logged once')
  _G.SN2_CHECK_HOST_BODY('/Game/Fake.HostPawn')
  check(#prints == before + 1, 'an already hidden pawn is silent')
  _G.print = real_print
end
do
  local src = assert(io.open(dir .. 'recipe.lua')):read('a')
  check(src:match('ExecuteInGameThread%(function%(%)%s+local ok, err = pcall%(function%(%)%s+local notice_players'),
    'notification game-thread callback wraps its whole body in pcall')
end
check(_G.SN2_PICK_SAVE('MyWorld') == 'MyWorld', 'an explicit save name wins')
do
  local src = assert(io.open(dir .. 'recipe.lua')):read('a')
  -- The direct sky clock stays opt-in until it is proven live; the console fallback is the
  -- path the host ran stable on.
  check(src:find("local SKY_CLOCK = os.getenv('SN2_SKY_CLOCK') == 'true'", 1, true) ~= nil,
    'the direct sky clock is off unless SN2_SKY_CLOCK=true')
  -- If the ability system is ever read again, it goes through the engine library, never a
  -- name looked up on the pawn (that walk trips a mis-laid-out array on the Blueprint pawn class).
  check(src:find('pawn:GetASC()', 1, true) == nil, 'no ASC is read by pawn:GetASC()')
  -- Out parameters need a table in their slot (UE4SS refuses a short call).
  check(src:find('GetPingDisplayName({}, PingId:get())', 1, true) ~= nil
    and not src:find('GetPingDisplayName%(id%)') and not src:find('GetPingDisplayName%(PingId:get%(%)%)'),
    'every GetPingDisplayName call passes its out table and the id')
end
-- WORLD_NAME: the Host call's ServerName (the game's SaveSlotDisplayName) comes from
-- SN2_WORLD_NAME, characters that would split the option string dropped, with a default.
do
  local src = assert(io.open(dir .. 'main.lua')):read('a')
  local fn = assert(src:match('(local function world_name%(%).-\nend)'), 'world_name not found')
  local function name_for(v)
    local saved = os.getenv
    os.getenv = function(k) if k == 'SN2_WORLD_NAME' then return v end return saved(k) end
    local wn = assert(load(fn .. '\nreturn world_name()'))()
    os.getenv = saved
    return wn
  end
  local cases = { { 'Johnny and Friends', 'Johnny and Friends' }, { nil, 'Subnautica 2 server' },
    { '   ', 'Subnautica 2 server' }, { 'Bad?Name=1&x', 'BadName1x' } }
  for _, c in ipairs(cases) do
    local got = name_for(c[1])
    if got ~= c[2] then fails = fails + 1; real_print('FAIL world_name(' .. tostring(c[1]) .. ') = ' .. got) end
  end
  -- both Host calls pass world_name() and save_slot(), never the old literal
  local n = 0
  for _ in src:gmatch('HostSession%w*%([^)]-world_name%(%), save_slot%(%)') do n = n + 1 end
  if n ~= 2 or src:find('HostSession%w*%([^)]-"Subnautica2Dedicated"') then
    fails = fails + 1; real_print('FAIL Host calls do not carry WORLD_NAME (' .. n .. ')')
  end
  -- the option string the game builds from it carries the operator's name
  local opts = '?listen?SaveSlotDisplayName=' .. name_for('My World') .. '?SaveSlotName=Slot1'
  if opts ~= '?listen?SaveSlotDisplayName=My World?SaveSlotName=Slot1' then
    fails = fails + 1; real_print('FAIL option string ' .. opts)
  end
end

-- The control folder's default follows DATA_DIR in both images (launcher exports SN2_DATA_WIN).
do
  local src = assert(io.open(dir .. 'recipe.lua')):read('a')
  local fn = assert(src:match('control_dir = (%(function%(%).-end%)%(%)),'), 'control_dir default not found')
  local function dir_for(e)
    local saved = os.getenv
    os.getenv = function(k) return e[k] end
    local d = assert(load('return ' .. fn))()
    os.getenv = saved
    return d
  end
  check(dir_for({ SN2_DATA_WIN = 'Z:\\home\\container' }) == 'Z:\\home\\container\\control',
    'panel image: control under /home/container')
  check(dir_for({ SN2_DATA_WIN = 'Z:\\data' }) == 'Z:\\data\\control', 'an explicit /data layout: control under /data')
  check(dir_for({ SN2_CONTROL_WIN = 'Z:\\x\\c', SN2_DATA_WIN = 'Z:\\data' }) == 'Z:\\x\\c',
    'an explicit control folder wins')
end

-- The join replay is its own job on the hosted poll, not a step at the end of
-- the log tail: a game log the mod cannot open (a real joiner got
-- no batch and no line said why) must neither skip it nor go unsaid, and the
-- launcher hands the mod the log's absolute path.
do
  local src = assert(io.open(dir .. 'recipe.lua')):read('a')
  local tail = assert(src:match('\nlocal function hold_poll%(%)(.-)\nend\n'), 'hold_poll not found')
  check(not tail:find('unlocks.joins', 1, true), 'the log tail no longer carries the join replay')
  check(tail:find("log('join hold: cannot read the game log", 1, true) ~= nil,
    'a log the mod cannot open is said in the mod log')
  local poll = assert(src:match('\nlocal function hosted_replay%(%)(.-)\nend\n'), 'hosted_replay not found')
  local guarded = poll:match('pcall%(function%(%)(.-)\n  end%)')
  check(guarded ~= nil and guarded:find('player_names()', 1, true) ~= nil
    and guarded:find('unlocks.joins(UNLOCKS, UNLOCK_GAME, named, HOST_NAME)', 1, true) ~= nil,
    'the join replay and its player lookup run inside one pcall')
  check(guarded ~= nil and guarded:find('is listed but has no controller by that name', 1, true) ~= nil,
    'a listed player the replay cannot reach is said once')
  check(poll:find("said_once('join replay'", 1, true) ~= nil, 'a join replay error is logged')
  local launcher = assert(io.open(dir .. '../../../scripts/launch-headless.sh')):read('a')
  check(launcher:find('SN2_GAME_LOG_WIN=$(winpath "$UE_LOG")', 1, true)
    ~= nil, 'the launcher exports the absolute game log path (common.sh picks it per executable)')
  check(launcher:match('\nexport [^\n]*SN2_GAME_LOG_WIN') ~= nil, 'SN2_GAME_LOG_WIN is exported')
  -- Wine's cmd has no reparse-point filter: /a:-d-l matched nothing and every
  -- request was refused as non_regular_file.
  local recipe = assert(io.open(dir .. 'recipe.lua')):read('a')
  check(recipe:find("dir /a:-d /b", 1, true) ~= nil and recipe:find("/a:-d-l", 1, true) == nil,
    'the inbox file check uses a filter Wine honours (/a:-d, no -l)')
end

-- An enabled_commands list equal to one the example config ever shipped is
-- not the operator's choice and gives way to the default; any other list is
-- the operator's own and is kept. The example ships no list now.
do
  local is_example = assert(_G.SN2_IS_EXAMPLE_LIST, 'recipe exposes is_example_list')
  check(is_example({ 'status', 'players', 'host', 'receipt', 'player' }),
    'the first example list (five commands) is an example list')
  check(is_example({ 'status', 'players', 'host', 'receipt', 'player', 'bring', 'slots', 'unlocks', 'waypoint',
    'settings' }), 'the last example list (ten commands) is an example list')
  check(not is_example({ 'status', 'players', 'host', 'receipt', 'player', 'bring', 'slots', 'friend_code',
    'unlocks', 'waypoint', 'settings' }), 'the full default list is kept')
  check(not is_example({ 'status', 'host' }), "a list with commands left out is the operator's")
  check(not is_example({ 'players', 'status', 'host', 'receipt', 'player' }), "another order is the operator's")
  check(not is_example({}), "an empty list is the operator's (everything refused)")
  check(not is_example(nil), 'no list is no list')
  local example = assert(io.open(dir .. '../config.example.json')):read('a')
  check(not example:find('enabled_commands', 1, true), 'the example config carries no enabled_commands list')
end

os.exit(fails == 0 and 0 or 1)
