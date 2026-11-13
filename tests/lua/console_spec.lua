-- Tests for mod/SN2SlotFreeHost/Scripts/console.lua with the shipped console.json and a fake game.
--   lua5.4 tests/lua/console_spec.lua   (from the repository root)
package.path = 'mod/SN2SlotFreeHost/Scripts/?.lua;' .. package.path
local console = require('console')
local json = require('json')

local failures = 0
local function check(cond, what)
  if cond then print('ok ' .. what) else failures = failures + 1; print('not ok ' .. what) end
end

local f = assert(io.open('mod/SN2SlotFreeHost/console.json', 'rb'))
local catalog = json.decode(f:read('a'))
f:close()

-- Every message key the code asks for exists in the catalog, so no reply is ever a bare key.
local missing = {}
for _, file in ipairs({ 'console.lua', 'recipe.lua' }) do
  local src = assert(io.open('mod/SN2SlotFreeHost/Scripts/' .. file, 'rb')):read('a')
  for key in src:gmatch("msg%(%w+, '([%w_]+)'") do
    if not catalog.messages[key] then missing[#missing + 1] = file .. ':' .. key end
  end
end
check(#missing == 0,
  'every message key the code uses is in console.json (missing: ' .. table.concat(missing, ' ') .. ')')

-- The game's AddTag and RemoveTag change a tag on one player; the cheats the console lists are the
-- world's, which only the Global commands change.
local per_player = {}
for name, c in pairs(catalog.commands) do
  for _, line in ipairs(c.lines) do
    if line:match('^AddTag ') or line:match('^RemoveTag ') then per_player[#per_player + 1] = name end
  end
end
check(#per_player == 0,
  'no shortcut changes a world cheat with a per-player command (' .. table.concat(per_player, ' ') .. ')')
local off = table.concat(catalog.commands.normal.lines, '|')
for _, tag in ipairs(catalog.tags) do
  check(off:find('RemoveGlobalTag ' .. tag, 1, true) ~= nil, 'off removes ' .. tag)
end

local data = {
  items = { { id = 'DA_Titanium_ItemType', name = 'Titanium' },
            { id = 'DA_TitaniumIngot_ItemType', name = 'Titanium Ingot' },
            { id = 'DA_Copper_ItemType', name = 'Copper' },
            { id = 'DA_Raft_ItemType', name = 'Raft' } },
  places = { { id = 'Lifepod', name = 'Lifepod' } },
  players = { { id = 'a', name = 'dirtbikr59', eos = '0002', ping = 40 },
              { id = 'b', name = 'Johnny Pappis', eos = '0003', ping = 60 } },
  commands = { { id = 'Give', name = 'Give' }, { id = 'HealMe', name = 'HealMe' },
               { id = 'ClearSaves', name = 'ClearSaves' } },
  tags = { { id = 'Cheat.FreeBuild', name = 'Cheat.FreeBuild' }, { id = 'Other.Thing', name = 'Other.Thing' } },
}
local game = { host = 'SN2 Host', list = function(kind) return data[kind] end }
local me = { name = 'dirtbikr59', key = '0002' }
local function run(text, st) return console.handle(st or console.new(catalog), { sender = me, text = text }, game) end

-- Shortcuts with arguments: the fewest letters that name one item are enough.
local r = run('g tit 10')
check(#r.runs == 0 and r.lines[1]:find('Titanium Ingot', 1, true), 'g tit 10: two items start with tit, so it asks')
r = run('g "titanium ingot" 10')
check(r.runs[1] and r.runs[1].line == 'Give DA_TitaniumIngot_ItemType 10' and r.runs[1].player == 'dirtbikr59',
  'a quoted full name resolves')
r = run('g cop')
check(r.runs[1] and r.runs[1].line == 'Give DA_Copper_ItemType 1', 'a unique prefix resolves, and count defaults')
r = run('g')
check(#r.runs == 0 and r.lines[1]:find('item', 1, true), 'a missing argument is named')

-- Targets: me by default, a fuzzy player, everyone, the host.
r = run('@john h')
check(#r.runs == 4 and r.runs[1].player == 'Johnny Pappis' and r.runs[1].line == 'HealMe',
  '@john h heals Johnny with every line')
r = run('@all HealMe')
check(#r.runs == 2, '@all runs for every player')
r = run('@zzz HealMe')
check(#r.runs == 0 and r.lines[1]:find('zzz', 1, true), 'an unknown player is refused by name')

-- Anything else passes through as typed, with "quoted names" resolved.
r = run('SpawnSomething 3')
check(r.runs[1] and r.runs[1].line == 'SpawnSomething 3', 'an unknown line passes through untouched')
r = run('Give "copper" 5')
check(r.runs[1] and r.runs[1].line == 'Give DA_Copper_ItemType 5', 'a quoted name inside a raw line resolves')

-- The deny list holds, also through @all and in any case.
r = run('@all ClearSaves')
check(#r.runs == 0 and r.lines[1]:find('clearsaves', 1, true), 'a denied command never runs')
r = run('CrashServerNow')
check(#r.runs == 0, 'a prefix pattern in the deny list holds')

-- Discovery.
r = run('f tita')
check(#r.lines >= 2 and r.lines[1]:find('DA_Titanium', 1, true), 'find lists matches with their ids')
r = run('tita')
check(#r.runs == 0 and r.lines[1]:find('DA_Titanium', 1, true), 'a lone word that is no command means find')
r = run('l i cop')
check(r.lines[1]:find('DA_Copper_ItemType', 1, true), 'ls with a kind alias and a filter')
r = run('l')
check(r.lines[1]:find('items', 1, true), 'ls without a kind names the kinds')
r = run('w')
check(#r.lines == 2 and r.lines[2]:find('Johnny Pappis', 1, true), 'who lists players with eos and ping')
r = run('c')
check(#r.lines == 1 and r.lines[1] == 'Cheat.FreeBuild', 'cheats lists only the cheat tags')
r = console.handle(console.new(catalog), { sender = me, text = 'c' }, { list = function() return nil end })
check(r.lines[1] == catalog.messages.cheats_unknown, 'cheats says so when the tags cannot be read')

-- Repeat.
local st = console.new(catalog)
run('g cop', st)
r = run('.', st)
check(r.runs[1] and r.runs[1].line == 'Give DA_Copper_ItemType 1', '. repeats the last line')
r = run('.', console.new(catalog))
check(#r.runs == 0, '. with nothing before says so')

-- Forgiving input: a number answers a question, words and the number in any order, no quotes needed.
st = console.new(catalog)
r = run('g tit 10', st)
check(#r.runs == 0 and r.lines[1]:find('1 Titanium  2 Titanium Ingot', 1, true), 'an unclear name asks with numbers')
r = run('2', st)
check(r.runs[1] and r.runs[1].line == 'Give DA_TitaniumIngot_ItemType 10', 'a bare number picks, and the line runs')
r = run('2', st)
check(#r.runs == 0 and not r.lines[1]:find('Ingot', 1, true), 'with no question waiting, a number picks nothing')
run('g tit', st)
r = run('9', st)
check(#r.runs == 0 and r.lines[1]:find('1 to 2', 1, true), 'a number past the choices says the range')
r = run('g 10 titanium ingot')
check(r.runs[1] and r.runs[1].line == 'Give DA_TitaniumIngot_ItemType 10', 'the number first, the name unquoted')
r = run('h')
check(#r.runs == #catalog.commands.heal.lines and r.runs[1].line == catalog.commands.heal.lines[1],
  'a shortcut with several lines runs each of them')
local first = json.decode(json.encode(catalog)); first.on_ambiguous = 'first'
r = console.handle(console.new(first), { sender = me, text = 'g tit' }, game)
check(r.runs[1] and r.runs[1].line == 'Give DA_Titanium_ItemType 1', 'on_ambiguous first takes the best match')

-- Help.
r = run('')
check(#r.runs == 0 and r.lines[1]:find('find', 1, true), 'an empty line shows help')

-- A message relayed between players' games: a cheat channel passes only from an admin, never a denied command.
local execute = catalog.cheat_channel .. '.Execute'
check(console.relay(st, 'GameplayMessage.HUDMessage.String', '(String="hello")', false) == true,
  'a message on another channel passes from anyone')
check(console.relay(st, execute, '(String="GetCoords")', true) == true, 'an admin may send a command to every game')
local pass, why = console.relay(st, execute, '(String="GetCoords")', false)
check(pass == false and why == 'not an admin', 'a player who is not an admin may not')
pass, why = console.relay(st, execute, '(String="CrashServer")', true)
check(pass == false and why:find('crashserver', 1, true) ~= nil, 'an admin may not send a denied command to every game')

-- Commands that carry other commands are refused whole: the deny list reads only the first word.
r = run('ExecuteForAll ClearSaves')
check(#r.runs == 0, 'a command that would run another on every game is refused')
r = run('RunMacro Anything')
check(#r.runs == 0, 'a macro started on the host, whose lines nobody checks, is refused')

-- Undo: a spawn line that names an item with a world class is remembered per player, newest last.
local u = console.new(catalog)
game.class_of = function(name) return ({ da_raft_itemtype = 'BP_Raft_C' })[name:lower()] end
check(console.spawned(u, 'k', 'Give DA_Raft_ItemType 1', game) == nil, 'a line that is not a spawn is not remembered')
check(console.spawned(u, 'k', 'Spawn DA_Copper_ItemType', game) == nil,
  'an item that puts nothing in the world is not remembered')
local got = console.spawned(u, 'k', 'spawn DA_Raft_ItemType 1', game)
check(got and got.class == 'BP_Raft_C' and got.name == 'DA_Raft_ItemType',
  'a spawn is remembered with the class its item puts in the world')
check(console.spawned(u, 'k', 'Spawn DA_RAFT_ItemType', game) ~= nil, 'whatever the case of the name')
r = console.handle(u, { sender = { name = 'dir', key = 'k' }, text = 'undo' }, game)
check(r.undo and r.undo.class == 'BP_Raft_C' and #r.runs == 0,
  'undo hands back the newest spawn and runs nothing itself')
console.handle(u, { sender = { name = 'dir', key = 'k' }, text = 'u' }, game)
r = console.handle(u, { sender = { name = 'dir', key = 'k' }, text = 'undo' }, game)
check(not r.undo and r.lines[1] == catalog.messages.undo_none, 'with nothing left, undo says so')
r = console.handle(u, { sender = { name = 'other', key = 'o' }, text = 'undo' }, game)
check(not r.undo, 'one player cannot undo the spawn of another')

-- A line from the game's own screens runs as it is, for its sender; the deny list still holds.
r = console.exact(st, { sender = { name = 'dir', key = 'k' }, text = 'Item DA_TestItem 2' })
check(#r.runs == 1 and r.runs[1].line == 'Item DA_TestItem 2' and r.runs[1].player == 'dir',
  'an exact line is not looked up')
r = console.forwarded(st, { sender = me, text = 'Give "copper" 5' }, game)
check(r.runs[1] and r.runs[1].line == 'Give "copper" 5', 'a forwarded game line is not looked up')
r = console.forwarded(st, { sender = me, text = catalog.signal_word .. ' Give "copper" 5' }, game)
check(r.runs[1] and r.runs[1].line == 'Give DA_Copper_ItemType 5',
  'a forwarded line with the console word is a console line')
r = console.exact(st, { sender = { name = 'dir', key = 'k' }, text = 'CrashServer' })
check(#r.runs == 0 and #r.lines == 1, 'an exact line on the deny list never runs')

if failures > 0 then os.exit(1) end
print('console: ok')
