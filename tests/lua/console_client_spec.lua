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
local row = route.search_text('DA_TitaniumIngot_ItemType', 'Titanium Ingot Resource', cfg.search.strip)
check(row == 'Titanium Ingot Resource TitaniumIngot',
  'a row is searched by its name, its category and its data name, without the shared parts')
check(route.matches(row, 'ing TIT') and route.matches(row, ''), 'typed words match as written, in any order and case')
check(route.matches(row, 'resource tit'), 'the category is a search word like any other')
check(not route.matches(row, 'tnm') and not route.matches(row, 'copper'), 'a word that is not there hides the row')
local knife = 'UWEItemType /Game/Data/ItemType/Tools/DA_Knife_ItemType.DA_Knife_ItemType'
check(knife:match(cfg.search.category) == 'Tools',
  'the category is the folder the item lives in')
check(cfg.search.every_ms > 0 and cfg.search.show_unpublished == false, 'unpublished items are hidden as shipped')
local typed_chars = {}
for _, ch in pairs(cfg.search.keys) do typed_chars[ch] = true end
check(typed_chars.a and typed_chars.z and typed_chars['0'] and typed_chars[' '] and cfg.search.erase,
  'with a list open, letters, digits and space type into the filter and one key takes one back')
local said = route.fill(cfg.hint.filtering, { query = 'tit', shown = 4, all = 208 })
check(said:find('tit', 1, true) and said:find('4 of 208', 1, true) and not said:find('{', 1, true),
  'the label over the command line shows what has been typed')
check(cfg.search.settle_ms >= cfg.search.every_ms, 'a list is given time to finish building before it is read')

local rules = { hide = { 'Button', 'Blur' }, keep = { 'ItemButton' } }
check(route.hidden('Button', 'GodButton', rules), 'a part of a hidden kind is hidden')
check(not route.hidden('Button', 'ItemButton', rules), 'a kept part stays')
check(not route.hidden('TextBox', 'Input', rules), 'a kind that is not listed stays')

-- The shipped settings keep the command line and what opens the pick lists.
local function shown(kind_, part_) return not route.hidden(kind_, part_, cfg.panel) end
check(shown('CommonTextBlock', cfg.hint.part) and #cfg.hint.text > 0,
  'the hint has words and its label stays on the panel')
check(shown('CommonTextBlock', 'Input') and shown('CommonTextBlock', 'autocomplete'), 'the command line stays')
check(shown('CommonTextButton_C', 'ItemButton') and not shown('CommonTextButton_C', 'GotoButton')
  and shown('CommonTextButton_C', 'MacroButton'), 'the pick lists stay, macros among them')
check(not shown('CommonTextButton_C', 'DiagMap') and not shown('HorizontalBox', 'StatCommandsContainer')
  and not shown('BackgroundBlur', 'BackgroundBlur_82'), 'the debug rows and the blur are hidden')
check(type(cfg.key) == 'string' and type(cfg.word) == 'string' and cfg.tries >= 1, 'the settings name a key and a word')
local at = cfg.layout
check(type(at.part) == 'string' and at.left >= 0 and at.left < at.right and at.right <= 1
  and at.top < cfg.list.top and cfg.list.top < cfg.list.bottom and cfg.list.bottom <= 1,
  'one column: the block hangs from the top, the list fills below it, all inside the screen')
check(cfg.nav.UP_ARROW == -1 and cfg.nav.DOWN_ARROW == 1 and cfg.run_key == 'RETURN',
  'the arrow keys move the choice one row and Enter runs it (UE4SS key names)')
check(not route.hidden('VerticalBox', at.part, cfg.panel), 'the block the layout places is not hidden')
check(#cfg.close.lists >= 1 and cfg.close.most >= 1 and cfg.close.wait_ms >= 0, 'closing names what it closes')

if failures > 0 then os.exit(1) end
print('console client: ok')
