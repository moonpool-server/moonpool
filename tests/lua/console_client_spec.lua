-- Tests for client-mods/MoonpoolConsole/Scripts/route.lua with the shipped config.lua.
--   lua5.4 tests/lua/console_client_spec.lua   (from the repository root)
local DIR = 'client-mods/MoonpoolConsole/Scripts/'
local route = dofile(DIR .. 'route.lua')
local cfg = dofile(DIR .. 'config.lua')

local failures = 0
local function check(cond, what)
  if cond then print('ok ' .. what) else failures = failures + 1; print('not ok ' .. what) end
end

local known = { healme = true, give = true }
local where, text = route.route('HealMe', known, 'mp')
check(where == route.GAME and text == nil, 'a game command is left to the game, whatever its case')
where, text = route.route('who', known, 'mp')
check(where == route.CONSOLE and text == 'mp who', 'another word goes to the console, led by its word')
where, text = route.route('  g tit 10', known, 'mp')
check(where == route.CONSOLE and text == 'mp   g tit 10', 'the typed line is sent as typed after the word')
where, text = route.route('MP who', known, 'mp')
check(where == route.CONSOLE and text == 'MP who', 'a line that already starts with the word is not given it twice')
check(route.route('', known, 'mp') == nil and route.route('   ', known, 'mp') == nil, 'an empty line goes nowhere')
where, text = route.route('HealMe', nil, 'mp')
check(where == route.CONSOLE and text == 'mp HealMe', 'with no command list every line goes to the console')

check(route.fill('{what} failed {tries} times', { what = 'x', tries = 3 }) == 'x failed 3 times',
  'a message is filled in')
for key, message in pairs(cfg.log) do
  check(type(message) == 'string' and message ~= '', 'the message ' .. key .. ' has words')
end
for key, name in pairs(cfg.game) do
  check(name ~= nil and name ~= '', 'the game name ' .. key .. ' is set')
end

check(type(cfg.back_key) == 'string' and cfg.back_key ~= cfg.key, 'stepping back has a key of its own')
check(cfg.toggle_gap_ms >= 100, 'a double press of the key is ignored')
check(cfg.game.last_class == 'CheatManager', 'the cheats of the engine itself are not counted as the game ones')
check(type(cfg.key) == 'string' and type(cfg.word) == 'string' and cfg.tries >= 1, 'the settings name a key and a word')
check(cfg.nav.UP_ARROW == -1 and cfg.nav.DOWN_ARROW == 1 and cfg.run_key == 'RETURN',
  'the arrow keys move the choice one row and Enter runs it (UE4SS key names)')
local at = cfg.layout
check(at.left >= 0 and at.left < at.right and at.right <= 1 and at.top >= 0 and at.top < 1,
  'the palette is inside the screen')
check(cfg.max_rows >= 1 and cfg.list_height > 0 and cfg.read_ms > 0 and cfg.answer_lines >= 1,
  'it keeps rows in a list of its own height and reads the search line while it shows')
for _, h in ipairs(cfg.hints) do
  check(type(h.label) == 'string' and type(h.key) == 'string' and h.key ~= '',
    'the hint ' .. h.label .. ' names its key')
end
local kinds = {}
for _, t in ipairs(cfg.tabs) do
  check(type(t.label) == 'string' and t.label ~= '', 'a tab has a label')
  kinds[t.kind or 'all'] = true
end
check(kinds.all and kinds.item and kinds.server and kinds.command and kinds.recent,
  'one tab for each kind of row, and one for all')
for _, a in ipairs(cfg.item_actions) do
  check(a.line:find('{id}', 1, true), 'the item action ' .. a.label .. ' names the item')
end
check(cfg.items.show_unpublished == false, 'unpublished items are hidden as shipped')
local knife = 'UWEItemType /Game/Data/ItemType/Tools/DA_Knife_ItemType.DA_Knife_ItemType'
check(knife:match(cfg.items.category) == 'Tools', 'the category is the folder the item lives in')
for key, message in pairs(cfg.text) do
  check(type(message) == 'string' and message ~= '', 'the text ' .. key .. ' has words')
end
for key, c in pairs(cfg.colors) do
  check(c.R and c.G and c.B and c.A and c.A <= 1, 'the colour ' .. key .. ' is R, G, B and A')
end

-- A number at the end of the search is how many: the search is the rest.
local search, count = route.count('glass 10')
check(search == 'glass' and count == 10, 'glass 10 searches glass and counts 10')
search, count = route.count('titanium ingot')
check(search == 'titanium ingot' and count == nil, 'no number, no count')
search, count = route.count('glass 0')
check(search == 'glass 0' and count == nil, 'a count of 0 is no count')

-- History: the lines run from the palette, newest first.
local recent = route.remember({}, 'help')
recent = route.remember(recent, 'Item DA_Glass_ItemType 10')
recent = route.remember(recent, ' help ')
check(recent[1] == 'help' and recent[2] == 'Item DA_Glass_ItemType 10' and #recent == 2,
  'a line run again moves to the front, once')
check(#route.remember({ 'a', 'b', 'c' }, 'd', 3) == 3, 'at most max lines are kept')
check(route.remember({ 'a' }, '  ')[1] == 'a', 'an empty line is not kept')

local function unfinished(name)
  for _, pattern in ipairs(cfg.items.unfinished) do if name:find(pattern) then return true end end
  return false
end
local marked = { '[PLACEHOLDER FIX OR DELETE]', '[PH] Resource Overflow', '[DEPRECATED] Old Tank', '[TEST] Box' }
for _, name in ipairs(marked) do
  check(unfinished(name), 'an item the game marks unfinished is hidden: ' .. name)
end
check(not unfinished('#LeviathanAwakens Poster') and not unfinished('Acid rain'), 'a finished item stays')

local base = { key = 'F2', layout = { top = 0.2, left = 0.36 }, tabs = { 'A', 'B' } }
route.merge(base, { key = 'F3', layout = { top = 0.1 }, tabs = { 'C' } })
check(base.key == 'F3' and base.layout.top == 0.1 and base.layout.left == 0.36,
  "a player's own settings change only the keys they name")
check(#base.tabs == 1 and base.tabs[1] == 'C', 'a list in them replaces the shipped list whole')
check(route.merge(base, 'not a table') == base, 'settings that are not a table change nothing')
local sandboxed = load("return { key = os and 'escaped' or 'kept' }", 'own', 't', {})
check(sandboxed().key == 'kept', 'the own-settings and own-rows files run with no libraries')
check(cfg.own_settings:find('Moonpool', 1, true) and cfg.own_commands:find('Moonpool', 1, true),
  "a player's own settings and rows live beside the palette's history")

if failures > 0 then os.exit(1) end
print('console client: ok')
