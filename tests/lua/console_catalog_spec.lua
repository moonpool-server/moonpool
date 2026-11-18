-- Tests for client-mods/MoonpoolConsole/Scripts/catalog.lua: the palette's entries and search.
--   lua5.4 tests/lua/console_catalog_spec.lua   (from the repository root)
local cat = dofile('client-mods/MoonpoolConsole/Scripts/catalog.lua')

local failures = 0
local function check(cond, what)
  if cond then print('ok ' .. what) else failures = failures + 1; print('not ok ' .. what) end
end
local function names(list) local o = {}; for i, e in ipairs(list) do o[i] = e.name end; return table.concat(o, ',') end

local actions = { { label = 'Give', line = 'Item {id} {count}' }, { label = 'Spawn', line = 'Spawn {id} {count}' },
  { label = 'Equip', line = 'Equip {id}', equippable = true } }
local items = cat.items({
  DA_AirBladder_ItemType = { label = 'Air Bladder', category = 'Equipment', published = true, equippable = true },
  DA_Algae_A = { label = 'Algae Block', category = 'Resource', published = true },
  DA_Algae_B = { label = 'Algae Block', category = 'Resource', published = true },
  DA_Secret = { label = 'Secret Thing', category = 'Tools', published = false },
  DA_Blank = { label = '', category = 'Tools', published = true },
}, actions, false)
check(#items == 3, 'unpublished items and items with no name are left out')
local found = cat.search(items, 'air')
check(#found == 1 and found[1].name == 'Air Bladder', 'one row per item: "air" finds Air Bladder once')
check(#found[1].actions == 3, 'an equippable item offers Give, Spawn and Equip')
local algae = cat.search(items, 'algae')
check(#algae == 2 and algae[1].detail ~= algae[2].detail, 'same-named items are told apart by their data id')
check(#algae[1].actions == 2, 'an item the game does not call equippable offers no Equip')
check(#cat.items({ DA_Secret = { label = 'Secret', category = '', published = false } }, actions, true) == 1,
  'show_unpublished shows them')

check(cat.line(found[1], found[1].actions[1], {}) == 'Item DA_AirBladder_ItemType 1',
  'an action fills in the id and the default count')
check(cat.line(found[1], found[1].actions[1], { count = 5 }) == 'Item DA_AirBladder_ItemType 5',
  'a given count is used')
check(cat.line(found[1], found[1].actions[3], { count = 5 }) == 'Equip DA_AirBladder_ItemType',
  'an action without a count sends none')

local host = cat.host_commands({ word = 'mp',
  commands = { give = { aliases = { 'give' },
    args = { { name = 'item', kind = 'items' }, { name = 'count', default = '1' } } },
               heal = { aliases = { 'heal' } } },
  verbs = { who = { 'who' }, ls = { 'list' } },
  help = { 'give titanium 10 · give john titanium 10: items', 'heal · heal john: to full', 'who: who is on',
           'list items cop · list commands: browse one kind' } })
local give = cat.search(host, 'give')[1]
check(give and give.detail == 'give titanium 10 · give john titanium 10: items', 'a server command shows its help line')
local line, missing = cat.line(give, give.actions[1], {})
check(line == nil and missing == 'item', 'a server command with an argument nobody gave says which')
check(cat.line(give, give.actions[1], { item = 'titanium' }) == 'mp give titanium 1',
  'a server command is led by its word')
local ls = cat.search(host, 'list')[1]
check(ls and ls.name == 'list' and ls.detail:find('^list items'), 'a verb is named by its first alias')
check(#cat.host_commands(nil) == 0 and #cat.host_commands({}) == 0, 'no server table, no server commands')

local game = cat.game_commands({ healme = 'HealMe', heal = 'Heal', healtarget = 'HealTarget' }, 'game')
local heal = cat.search(game, 'heal')
check(names(heal) == 'Heal,HealMe,HealTarget', 'a name that starts with the query comes first, shorter first')
check(names(cat.search(game, 'target')) == 'HealTarget', 'a word anywhere still matches')
local mixed = { { key = 'a', name = 'Repair Tool', detail = '', kind = 'item' },
                { key = 'b', name = 'Unrepaired', detail = '', kind = 'item' },
                { key = 'c', name = 'Tool Repair', detail = '', kind = 'item' } }
check(names(cat.search(mixed, 'repair')) == 'Repair Tool,Tool Repair,Unrepaired',
  'name start, then a word start, then anywhere')
check(names(cat.search(mixed, '', nil, nil, { c = true })) == 'Tool Repair,Unrepaired,Repair Tool',
  'pinned first when nothing is typed')
local top, all = cat.search(mixed, '', 2)
check(#top == 2 and all == 3, 'limit cuts the rows but the count says how many matched')
check(#cat.search(mixed, 'repair', nil, 'command') == 0, 'a kind limits the search to it')
check(names(cat.search(mixed, 'r.p')) == '', 'a query is matched as text, not as a pattern')

local own = cat.own({ { name = 'Day', line = 'DayOnly 1' }, { name = 'bad' }, 'junk' })
check(#own == 1 and cat.line(own[1], own[1].actions[1]) == 'DayOnly 1',
  "a player's own entry runs its line; bad ones are skipped")

local old = cat.items({ DA_Old = { label = 'Old Sponge', category = 'Deprecated', published = true } }, actions, false,
  { 'Deprecated' })
check(#old == 0, "an item in a folder the game keeps for old things is hidden")
local rules = { { '^Spawn ', '{word} undo' }, { '^mp tag (%S+)$', 'mp untag %1' },
  { '^DayOnly 1$', 'DayOnly 0' }, { '^(God)$', '%1' } }
check(cat.opposite('Spawn DA_Seamoth 1', rules, 'adm') == 'adm undo', 'a spawn is undone by the server')
check(cat.opposite('mp tag Cheat.Fly', rules) == 'mp untag Cheat.Fly', 'a capture is carried into the undo')
check(cat.opposite('DayOnly 1', rules) == 'DayOnly 0' and cat.opposite('God', rules) == 'God',
  'a setting is set back; a toggle is pressed again')
check(cat.opposite('Item DA_Glass 10', rules) == nil, 'nothing is offered where nothing undoes it')
local mac = cat.macros({ { name = 'QuickNav', detail = 'fast travel' } })
check(#mac == 1 and mac[1].kind == 'macro' and cat.line(mac[1], mac[1].actions[1]) == 'RunMacro QuickNav'
  and mac[1].actions[1].local_run, 'a macro runs through the game on this PC')

local mine = cat.own({ { name = 'Night shift', detail = 'dark, frozen', args = { { name = 'hour', default = '22' } },
  actions = { { label = 'Start', line = 'SetTimeOfDay {hour}' }, { label = 'Stop', line = 'UnfreezeTime' } } },
  { name = 'Local', line = 'stat fps', local_run = true }, { name = 'No actions', actions = { 'junk' } } })
check(#mine == 2, 'own rows with several actions or one line are kept; one with no usable action is skipped')
check(cat.line(mine[1], mine[1].actions[1], {}) == 'SetTimeOfDay 22' and mine[1].actions[2].label == 'Stop',
  'an own row fills its own arguments and offers each of its actions')
check(mine[2].actions[1].local_run and not mine[1].actions[1].local_run, 'only a row that says so runs on this PC')

check(cat.draft(found[1], found[1].actions[1], {}) == 'Item DA_AirBladder_ItemType 1',
  'the line to edit is the whole line an item action would send')
check(cat.draft(give, give.actions[1], {}) == 'mp give ', 'a server command is drafted up to the argument still needed')

check(cat.list_line('Item {0} 1') == 'Item {id} {count}' and cat.list_line('Equip {0}') == 'Equip {id}',
  "a game list's command becomes the action's line, its number the count")
check(cat.list_line('Summon') == nil, 'a command that names no item gives no action')
local acts = cat.list_actions({ { label = 'Give', command = 'Item {0} 1', ids = { DA_Ti = true } },
  { label = 'Spawn', command = 'Spawn {0} 1', ids = { DA_Ti = true, DA_Tadpole = true } },
  { label = 'Equip', command = 'Equip {0}', ids = {} } })
check(#acts == 2, 'a list that could not be read is left out')
local placed = cat.items({ DA_Tadpole = { label = 'Tadpole', category = '', published = true },
  DA_Ti = { label = 'Titanium', category = 'Resource', published = true } }, acts)
local by = {}
for _, e in ipairs(placed) do by[e.name] = e end
check(#by.Tadpole.actions == 1 and by.Tadpole.actions[1].label == 'Spawn' and #by.Titanium.actions == 2,
  "each item gets only the actions whose game list holds it: Tadpole spawns, Titanium gives and spawns")
check(cat.line(by.Titanium, by.Titanium.actions[1], { count = 5 }) == 'Item DA_Ti 5',
  "the game's own command, with the count")
check(cat.list_actions({ { label = 'Give', command = 'Item {0} 1', ids = {} } }) == nil,
  'no list read: nil, so the caller keeps its own actions')

check(give.signature == 'mp give  <item: items>  [count = 1]',
  'a server command shows its arguments, a default in brackets')
local sig = cat.game_commands({ give = 'Give' }, '', { Give = { { name = 'ItemName', kind = 'text' },
  { name = 'Amount', kind = 'number' } } })[1].signature
check(sig == 'Give  <ItemName: text>  <Amount: number>', "a game command shows its parameters and their kinds")

local shown = cat.items({ DA_A = { label = 'Algae Block', category = 'Resource', published = true },
  DA_B = { label = 'Algae Block', category = 'Resource', published = true },
  DA_C = { label = 'Copper', category = 'Resource', published = true } }, actions)
local det = {}
for _, e in ipairs(shown) do det[e.id] = e.detail end
check(det.DA_C == 'Resource', "an item's second line is its category in the game's data")
check(det.DA_A == 'Resource · DA_A' and det.DA_B == 'Resource · DA_B', 'the data name is added where names are shared')
local mixed2 = { { kind = 'recent', name = 'give glass' }, { kind = 'item', name = 'Glass' } }
check(#cat.searchable(mixed2, nil, 'gla') == 1 and #cat.searchable(mixed2, nil, '') == 2
  and #cat.searchable(mixed2, 'recent', 'gla') == 2, 'recent lines show on their tab, or on All with nothing typed')
check(cat.give_for('{word} @{who} give {id} {count}', 'mp', 'Johnny Pappis', 'DA_Copper_ItemType', 5)
  == 'mp @Johnny give DA_Copper_ItemType 5', "giving to someone else goes through the server, by the name's first word")
check(cat.give_for('{word} @{who} give {id} {count}', 'mp', 'all', 'DA_X', nil) == 'mp @all give DA_X 1',
  'everyone, with the count defaulting to 1')

if failures > 0 then os.exit(1) end
print('console catalog: ok')
