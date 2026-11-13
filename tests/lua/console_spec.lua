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

local data = {
  items = { { id = 'DA_Titanium_ItemType', name = 'Titanium' },
            { id = 'DA_TitaniumIngot_ItemType', name = 'Titanium Ingot' },
            { id = 'DA_Copper_ItemType', name = 'Copper' } },
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

-- Help.
r = run('')
check(#r.runs == 0 and r.lines[1]:find('find', 1, true), 'an empty line shows help')

if failures > 0 then os.exit(1) end
print('console: ok')
