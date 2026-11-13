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

check(cfg.game.last_class == 'CheatManager', 'the cheats of the engine itself are not counted as the game ones')
local row = route.search_text('DA_TitaniumIngot_ItemType', 'Titanium Ingot', cfg.search.strip)
check(row == 'Titanium Ingot TitaniumIngot',
  'a row is searched by its name and its data name, without the shared parts')
check(route.matches(row, 'ing TIT') and route.matches(row, ''),
  'typed words match as written, in any order and any case')
check(not route.matches(row, 'tnm') and route.matches(row, 'tnm', true), 'letters in order count only when loose')
check(not route.matches(row, 'copper') and not route.matches(row, 'tit x', true),
  'a word that is not there hides the row')
check(not route.matches('Advanced Wiring Kit AdvancedWiringKit', 'tnm', true),
  'loose letters must sit in one word that starts alike')
check(cfg.search.every_ms > 0 and cfg.search.show_unpublished == false, 'unpublished items are hidden as shipped')
check(cfg.search.settle_ms >= cfg.search.every_ms, 'a list is given time to finish building before it is read')

local rules = { hide = { 'Button', 'Blur' }, keep = { 'ItemButton' } }
check(route.hidden('Button', 'GodButton', rules), 'a part of a hidden kind is hidden')
check(not route.hidden('Button', 'ItemButton', rules), 'a kept part stays')
check(not route.hidden('TextBox', 'Input', rules), 'a kind that is not listed stays')

local base = '/Engine/Transient.Game_1:Instance_2.WBP_CheatInput_C_3'
local part, kind = route.part_of('CommonTextButton_C ' .. base .. '.WidgetTree_4.GodButton', base)
check(part == 'GodButton' and kind == 'CommonTextButton_C', 'a part directly in the panel is named with its kind')
check(route.part_of('CommonTextBlock ' .. base .. '.WidgetTree_4.GodButton.WidgetTree_5.TextLabel', base) == nil,
  'a part inside one of the panel\'s buttons is left alone')
check(route.part_of('CommonTextBlock /Engine/Transient.Other_9.WidgetTree_4.Input', base) == nil,
  'a part of another panel is left alone')

-- The shipped settings keep the command line and what opens the pick lists.
local function shown(kind_, part_) return not route.hidden(kind_, part_, cfg.panel) end
check(shown('CommonTextBlock', 'Input') and shown('CommonTextBlock', 'autocomplete'), 'the command line stays')
check(shown('CommonTextButton_C', 'ItemButton') and shown('CommonTextButton_C', 'GotoButton')
  and shown('CommonTextButton_C', 'MacroButton'), 'the pick lists stay, macros among them')
check(not shown('CommonTextButton_C', 'DiagMap') and not shown('HorizontalBox', 'StatCommandsContainer')
  and not shown('BackgroundBlur', 'BackgroundBlur_82'), 'the debug rows and the blur are hidden')
check(type(cfg.key) == 'string' and type(cfg.word) == 'string' and cfg.tries >= 1, 'the settings name a key and a word')
local at = cfg.layout
check(type(at.part) == 'string' and at.left >= 0 and at.left < at.right and at.right <= 1 and at.bottom > 0
  and at.bottom <= 1, 'the layout is a span of the screen standing on a line inside it')
check(not route.hidden('VerticalBox', at.part, cfg.panel), 'the block the layout places is not hidden')
check(#cfg.close.lists >= 1 and cfg.close.most >= 1 and cfg.close.wait_ms >= 0, 'closing names what it closes')

if failures > 0 then os.exit(1) end
print('console client: ok')
