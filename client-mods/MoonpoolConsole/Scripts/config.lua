-- Settings for the admin palette. Data only: edit and restart the game. A player's own changes go in
-- own_settings (below), a file that returns only the keys to change.
return {
  -- The key that shows the palette and, pressed again, closes it (a name from UE4SS's Key table).
  key = 'F2',
  -- After a press of the key, further presses are ignored for this long.
  toggle_gap_ms = 500,
  -- Keys while the palette shows: back closes it; up and down move the choice; run sends the chosen
  -- row's action at once (or, when nothing matches, the typed line); edit_key puts the exact line it
  -- would send into the search line instead, to change before Enter; action_keys (with action_modifier)
  -- step through a row's actions (Give, Spawn, Equip).
  back_key = 'ESCAPE',
  nav = { UP_ARROW = -1, DOWN_ARROW = 1 },
  run_key = 'RETURN',
  edit_key = 'TAB',
  action_keys = { LEFT_ARROW = -1, RIGHT_ARROW = 1 },
  -- With action_modifier: who an item is for (the player, another player, everyone).
  target_keys = { UP_ARROW = -1, DOWN_ARROW = 1 },
  action_modifier = 'CONTROL',
  -- Page keys move the choice a page of rows (page_rows) at a time.
  page_keys = { PAGE_UP = -1, PAGE_DOWN = 1 },
  page_rows = 7,
  -- The mouse picks a tab, a row or an action with click_key.
  click_key = 'LEFT_MOUSE_BUTTON',
  -- Alt and a number shows that tab (1 is the first); plain digits stay in the search, as its count.
  tab_number_keys = { 'ONE', 'TWO', 'THREE', 'FOUR', 'FIVE', 'SIX', 'SEVEN', 'EIGHT', 'NINE' },
  tab_number_modifier = 'ALT',
  -- The word the server's console listens for (signal_word in the server's console.json). The
  -- server's own word, from host-commands.lua, is used when that file is there.
  word = 'mp',
  -- A call into the game that fails is tried again up to this many times; a call that needed more than
  -- one try is logged once, so the number can be set from what this build does.
  tries = 3,
  -- How often the search line is read while the palette shows. Nothing runs while it is hidden.
  read_ms = 100,
  -- Where the palette sits, as shares of the screen: from left to right, hanging from top.
  layout = { left = 0.33, right = 0.67, top = 0.16 },
  -- The results scroll in a list at most list_height tall (screen units before scaling); at most
  -- max_rows of them are kept, the best first. answer_lines: lines of a server answer shown.
  list_height = 420,
  max_rows = 60,
  answer_lines = 4,
  -- Colours (R, G, B, A from 0 to 1) and text sizes.
  colors = {
    surface = { R = 0.012, G = 0.035, B = 0.07, A = 1.0 },
    field = { R = 0.005, G = 0.02, B = 0.045, A = 1.0 },
    chosen = { R = 0.02, G = 0.32, B = 0.42, A = 1.0 },
    row = { R = 0, G = 0, B = 0, A = 0 },
    text = { R = 0.92, G = 0.97, B = 1.0, A = 1.0 },
    muted = { R = 0.55, G = 0.68, B = 0.78, A = 1.0 },
    dim = { R = 0.38, G = 0.48, B = 0.56, A = 1.0 },
    accent = { R = 0.35, G = 0.85, B = 0.95, A = 1.0 },
    amber = { R = 1.0, G = 0.75, B = 0.3, A = 1.0 },
    failed = { R = 1.0, G = 0.45, B = 0.4, A = 1.0 },
    key = { R = 0.05, G = 0.16, B = 0.24, A = 1.0 },
  },
  sizes = { title = 18, field = 22, row = 19, detail = 13, small = 14 },
  padding = 14,
  -- The tabs, in order: a label and the kind of row it shows (nil: all).
  tabs = { { label = 'All' }, { label = 'Items', kind = 'item' }, { label = 'Server', kind = 'server' },
    { label = 'Game', kind = 'command' }, { label = 'Macros', kind = 'macro' },
    { label = 'Mine', kind = 'own' }, { label = 'Recent', kind = 'recent' } },
  -- The game's macros come from its own Macro list (game.lists.macro), run here by that list's own
  -- command, which sends their lines to the server one by one; the server checks each. This list is
  -- used only when the game's cannot be read.
  macros = {
    { name = 'Base Pack', detail = 'gives items' }, { name = 'Equipment Pack', detail = 'gives items' },
    { name = 'Starting Items', detail = 'gives items' },
    { name = 'QuickNav', detail = 'no fog, speed, fast swim; day frozen at noon for the world' },
    { name = 'Superman', detail = 'god, fast build, unlock all, invisible, fast swim' },
    { name = 'SculptDebug', detail = 'habitat builder, god, free build, unlimited power' },
  },
  run_macro = 'RunMacro {id}',
  -- What undoes a line: { Lua pattern over the line sent, the line that undoes it } with %1.. for the
  -- pattern's captures and {word} for the server's word. A row run before offers Undo when one applies.
  -- Toggles undo by running again; an item given cannot be taken back, so it offers none.
  opposites = {
    { '^Spawn ', '{word} undo' },
    { '^%S+ tag (%S+)$', '{word} untag %1' }, { '^%S+ untag (%S+)$', '{word} tag %1' },
    { '^AddGlobalTag (%S+)$', 'RemoveGlobalTag %1' }, { '^RemoveGlobalTag (%S+)$', 'AddGlobalTag %1' },
    { '^FreezeTime', 'UnfreezeTime' }, { '^UnfreezeTime', 'FreezeTime' },
    { '^DayOnly 1', 'DayOnly 0' }, { '^DayOnly 0', 'DayOnly 1' },
    { '^RunMacro QuickNav', 'NormalNav' }, { '^RunMacro Superman', '{word} normal' },
    { '^RunMacro SculptDebug', '{word} normal' },
    { '^(God)$', '%1' }, { '^(Fly)$', '%1' }, { '^(NoClip)$', '%1' }, { '^(Invisible)$', '%1' },
    { '^(FreeBuild)$', '%1' }, { '^(FastSwim)$', '%1' }, { '^(UnlimitedPower)$', '%1' },
  },
  -- The actions an item row offers come from the game's own cheat lists: each list's command ("Item {0}
  -- 1") is the action's line, and an item gets the action only if that list holds it (so a Tadpole,
  -- which the Item list leaves out, only spawns). label: the action's name; list: which of the game's
  -- lists (game.lists below). A number at the end of the search ("glass 10") is the count.
  -- item_actions is used only when the game's lists cannot be read; then Equip is offered where the
  -- game calls an item equippable.
  list_actions = { { label = 'Give', list = 'item' }, { label = 'Spawn', list = 'spawn' },
    { label = 'Equip', list = 'equip' } },
  item_actions = {
    { label = 'Give', line = 'Item {id} {count}' },
    { label = 'Spawn', line = 'Spawn {id} {count}' },
    { label = 'Equip', line = 'Equip {id}', equippable = true },
  },
  -- Items the game itself calls unpublished, or whose name marks them unfinished, are left out unless
  -- show_unpublished is true. category: the item's folder in the game's data, a Lua pattern.
  items = { show_unpublished = false, category = '/ItemType/([%w_]+)/', hidden_categories = { 'Deprecated' },
    unfinished = { '^%[DEPRECATED', '^%[PLACEHOLDER', '^%[PH%]', '^%[TEST' } },
  -- The key hints along the bottom: a word and the key in a box. A hint with an action is the game's
  -- own hint for that action (game.hint_widget), which shows the key the player has bound to it.
  -- core: shown always; the rest only after keys_key (F1).
  keys_key = 'F1',
  hints = { { label = 'Send', key = 'Enter', core = true }, { label = 'Edit first', key = 'Tab', core = true },
    { label = 'Action', key = 'Ctrl+Left Right' }, { label = 'For', key = 'Ctrl+Up Down' },
    { label = 'Tabs', key = 'Alt 1-7' },
    { label = 'Page', key = 'PgUp PgDn' }, { label = 'Close', key = 'Esc', action = 'CloseAction', core = true },
    { label = 'Keys', key = 'F1', core = true } },
  -- Who an item is for: the player (the game's own actions), another player in the game, or everyone.
  -- For someone else the line is the server's give (give_for: {word}, {who}, {id}, {count}), which
  -- picks Give or Spawn from the game's own lists. everyone_word is the server's word for all players.
  max_targets = 8,
  give_for = '{word} @{who} give {id} {count}',
  everyone_word = 'all',
  -- Words the palette shows.
  text = {
    title = 'MOONPOOL',
    preview = 'Enter sends: {line}',
    for_label = 'For:',
    me = 'Me',
    everyone = 'Everyone',
    found = '{count} results',
    found_more = '{shown} of {count} results',
    none = 'Nothing matches. Enter sends the line as typed.',
    sent = 'Sent: {line}',
    undo = 'Sent: {line}    Undo: {undo}',
    answer = '{header}: {text}',
    missing = '{arg} is needed: type it after the name',
    looking = 'Looking at {name}, {x} {y} {z} m',
    game_detail = "the game's command",
    recent_detail = 'run before',
  },
  -- The lines run from the palette, newest first (at most keep), in file under %LOCALAPPDATA%: the
  -- launcher's folder, which an uninstall removes.
  history = { file = '\\Moonpool\\console-recent.txt', keep = 50 },
  -- A player's own changes to any setting here, if that file exists: a Lua file that returns a table
  -- with only the keys to change, e.g. return { key = 'F3', layout = { top = 0.1 } }.
  own_settings = '\\Moonpool\\console-settings.lua',
  -- A player's own rows, if that file exists: a Lua file run with no libraries that returns a list of
  -- rows shaped like the built-in ones (catalog.lua, own), shown under Mine and in every search, e.g.
  --   return { { name = 'Daylight', line = 'DayOnly 1' },
  --     { name = 'Night shift', args = { { name = 'hour', default = '22' } },
  --       actions = { { label = 'Start', line = 'SetTimeOfDay {hour}' },
  --                   { label = 'Stop', line = 'UnfreezeTime' } } } }
  -- Rows for everyone on a server belong in the server's console.json instead: its commands reach this
  -- palette through host-commands.lua.
  own_commands = '\\Moonpool\\console-commands.lua',
  -- The server's commands, written into this mod by the server when it publishes it.
  host_commands = 'host-commands.lua',
  -- The server's answers, read from the game's notification as it arrives (header and text only).
  -- Off: the answer shows only as the game's own card.
  answers = true,
  -- What closing also closes, through the game's own commands: its diagnostic windows.
  close_commands = { 'CloseDiag' },
  -- After the palette closes: what the world needs back, each with the game's function that says it
  -- is still held and the one that lets it go.
  give_back = {
    { name = 'mouse look', held = '/Script/Engine.Controller:IsLookInputIgnored',
      release = '/Script/Engine.Controller:ResetIgnoreLookInput' },
    { name = 'movement', held = '/Script/Engine.Controller:IsMoveInputIgnored',
      release = '/Script/Engine.Controller:ResetIgnoreMoveInput' },
  },
  -- What this mod says in UE4SS.log.
  log = {
    tag = '[MoonpoolConsole] ',
    ready = '{key} shows and closes the admin palette',
    bad_key = 'config.lua names a key UE4SS does not know: {key}',
    failed = '{what} failed {tries} times: {error}',
    retried = '{what} needed {tries} tries',
    missing = 'the game has no {what}',
    not_made = 'the game did not create the panel',
    no_part = 'the palette is off: {what}',
    error = 'the palette could not be shown or closed: {error}',
    gave_back = '{what} was still held after the palette closed; handed back to the game',
    entries = '{items} items, {game} game commands, {server} server commands, {own} own rows, '
      .. '{macros} macros from {from}',
    no_lists = "the game's item lists could not be read; items offer the actions in item_actions",
    no_answers = 'server answers show only as the game card: {error}',
    own_bad = 'own rows not read from {file}: {error}',
    timing = '{what} took {ms} ms',
    key = 'key: {what}',
  },
  trace = false,              -- true: log each key the palette acts on, and how long opening and searching take
  -- The game's own names this mod uses. They change only when the game does.
  game = {
    -- The game's cheat panel is the palette's shell: its parts are hidden and the palette is built
    -- in its place, so the game's own menu handling (focus, Esc, input) still applies.
    panel = '/Game/Blueprints/UI/Cheat/WBP_CheatInput.WBP_CheatInput_C',
    panel_class = 'WBP_CheatInput_C',
    font_from = 'Input',                -- the label whose font the palette's text uses
    controller = 'SN2PlayerController', -- the player in the world; the menus have a controller of their own
    server_cheat = 'SN2PlayerController:ServerCheat', -- named when sending a line fails
    template_prefix = 'Default__',      -- a class's own template object, never a live one
    last_class = 'CheatManager',        -- the walk up the cheat manager's classes ends here
    widgets = '/Script/UMG.Default__WidgetBlueprintLibrary',
    system = '/Script/Engine.Default__KismetSystemLibrary',
    tree = 'WidgetTree',
    root = 'RootWidget',
    canvas = '/Script/UMG.CanvasPanel',
    add_to_canvas = '/Script/UMG.CanvasPanel:AddChildToCanvas',
    child_count = '/Script/UMG.PanelWidget:GetChildrenCount',
    child_at = '/Script/UMG.PanelWidget:GetChildAt',
    add_child = '/Script/UMG.PanelWidget:AddChild',
    vertical = '/Script/UMG.VerticalBox',
    horizontal = '/Script/UMG.HorizontalBox',
    wrap_box = '/Script/UMG.WrapBox',
    border = '/Script/UMG.Border',
    text_block = '/Script/UMG.TextBlock',
    textbox_class = '/Script/UMG.EditableText',
    set_content = '/Script/UMG.ContentWidget:SetContent',
    set_text = '/Script/UMG.TextBlock:SetText',
    set_font = '/Script/UMG.TextBlock:SetFont',
    set_text_color = '/Script/UMG.TextBlock:SetColorAndOpacity',
    set_brush_color = '/Script/UMG.Border:SetBrushColor',
    set_border_padding = '/Script/UMG.Border:SetPadding',
    set_slot_padding_v = '/Script/UMG.VerticalBoxSlot:SetPadding',
    set_slot_padding_h = '/Script/UMG.HorizontalBoxSlot:SetPadding',
    set_slot_padding_w = '/Script/UMG.WrapBoxSlot:SetPadding',
    textbox_get = '/Script/UMG.EditableText:GetText',
    textbox_set = '/Script/UMG.EditableText:SetText',
    textbox_font = '/Script/UMG.EditableText:SetFont',
    textbox_style = 'WidgetStyle',
    style_color = 'ColorAndOpacity',
    label_font = 'Font',
    set_visibility = '/Script/UMG.Widget:SetVisibility',
    has_focus = '/Script/UMG.Widget:HasKeyboardFocus',
    is_hovered = '/Script/UMG.Widget:IsHovered',
    size_box = '/Script/UMG.SizeBox',
    set_max_height = '/Script/UMG.SizeBox:SetMaxDesiredHeight',
    scroll_box = '/Script/UMG.ScrollBox',
    scroll_into_view = '/Script/UMG.ScrollBox:ScrollWidgetIntoView',
    scroll_to_start = '/Script/UMG.ScrollBox:ScrollToStart',
    set_wrap = '/Script/UMG.TextBlock:SetAutoWrapText',
    run_local = 'ExecuteConsoleCommand',  -- the game's own console on this PC, for RunMacro
    keyboard_focus = '/Script/UMG.Widget:SetKeyboardFocus',
    set_anchors = '/Script/UMG.CanvasPanelSlot:SetAnchors',
    set_alignment = '/Script/UMG.CanvasPanelSlot:SetAlignment',
    set_auto_size = '/Script/UMG.CanvasPanelSlot:SetAutoSize',
    set_offsets = '/Script/UMG.CanvasPanelSlot:SetOffsets',
    set_z = '/Script/UMG.CanvasPanelSlot:SetZOrder',
    item_class = 'UWEItemType',
    item_label = 'Name',
    item_category = 'Category',          -- an item's category tag, its name in tag_name
    tag_name = 'TagName',
    is_published = '/Script/UWEAssetRegistry.UWEPrimaryDataAssetBase:IsPublished',
    is_equippable = '/Script/UWEInventory.UWEItemType:IsEquippable',
    -- The server's answer arrives as the game's notification, on this player's own component.
    notify = '/Script/UWENotifications.UWENotificationComponent:ClientNotify',
    -- What the player looks at: the controller's interaction component and its selected target.
    interact = 'InteractComp',
    target = '/Script/UWEInteract.UWEInteractComponent:GetSelectedTargetActor',
    location = '/Script/Engine.Actor:K2_GetActorLocation',
    -- The cheat panel's own lists: the button that opens each and the panel's handler for its click,
    -- which fills the list's view model (list_model) with the items it holds (each a list_item with
    -- its data name in list_id). hide_list is the game's command that closes the open list.
    -- (list_handler with the button's name and the handler's number in the panel's graph).
    lists = { item = { button = 'ItemButton', event = 0 }, spawn = { button = 'SpawnButton', event = 4 },
      equip = { button = 'EquipButton', event = 2 }, macro = { button = 'MacroButton', event = 1 } },
    list_handler = 'BndEvt__WBP_CheatInput_{button}_K2Node_ComponentBoundEvent_{event}'
      .. '_CommonButtonBaseClicked__DelegateSignature',
    list_model = 'SN2CheatListViewModel',
    list_command = 'ConsoleCommand',
    list_items = 'Items',
    list_id = 'Context',
    list_title = 'Title',
    game_state = 'GameStateBase',        -- the game's player list (player_array), each a name
    player_array = 'PlayerArray',
    player_name = 'PlayerNamePrivate',
    hide_list = 'HideModal',
    list_widget = 'WBP_CheatListSelector_C',  -- the list on screen
    is_activated = '/Script/CommonUI.CommonActivatableWidget:IsActivated',
    hint_widget = '/Game/Blueprints/UI/GenericUIElements/GenericUI_WBP/WBP_InputHintText.WBP_InputHintText_C',
    hint_set_text = '/Script/Subnautica2.SN2InputSymbolTextBlock:SetText',
    hint_rebuild = '/Script/Subnautica2.SN2InputSymbolTextBlock:OnControlMappingsRebuilt',
    hint_text = '{label} ([{action}])',  -- how the game writes its own hints: "Close ([CloseAction])"
    activate = '/Script/CommonUI.CommonActivatableWidget:ActivateWidget',
    deactivate = '/Script/CommonUI.CommonActivatableWidget:DeactivateWidget',
    -- ESlateVisibility: the shell takes clicks only on its own parts (SelfHitTestInvisible).
    shown = 4,
    -- A tab, row or action takes the mouse (Visible): borders and other containers start out letting
    -- it through to what is under them, and are then never hovered.
    clickable = 0,
    hidden = 2,      -- not drawn, but keeps its space
    collapsed = 1,   -- not drawn and takes no space
    layer = 1000,                       -- above the game's own screens
  },
}
