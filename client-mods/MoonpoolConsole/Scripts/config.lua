-- Settings for the admin console panel. Data only: edit and restart the game.
return {
  -- The key that shows the panel and, pressed again, closes it and everything it opened
  -- (a name from UE4SS's Key table).
  key = 'F2',
  -- After a press of the key, further presses are ignored for this long.
  toggle_gap_ms = 500,
  -- The key that steps back: open lists close first, then the panel. It does nothing while the panel
  -- is not showing.
  back_key = 'ESCAPE',
  -- The word the server's console listens for (signal_word in the server's console.json).
  word = 'mp',
  -- Calls into the game fail now and then on this build; each is tried this many times.
  tries = 40,
  -- The panel and the game's pick lists make one column, so the tabs, the filter and the results are
  -- one palette in one place. All as shares of the screen: the column runs from left to right; the
  -- panel's block (part: the game's name for it: tabs, filter line, command line) hangs from top; an
  -- open list's frame (list.part) fills from list.top to list.bottom, above the hotbar, darkened by
  -- list.tint (multiplied into the game's own frame colour). The panel's own blur (backdrop.part, blur
  -- strength) sits behind the block. It cannot go behind the list: the panel stays above the game's
  -- lists, because below them the game takes Esc for its own menu.
  layout = { part = 'VerticalBox_199', left = 0.36, right = 0.64, top = 0.215 },
  -- list.label: the list's own line under its title, where the filter and its count are shown; depth:
  -- how far into the list's widgets its frame and that line are.
  list = { part = 'CommonBorder_0', label = 'Description', depth = 3, top = 0.335, bottom = 0.86,
    tint = { R = 0.45, G = 0.45, B = 0.5, A = 1.0 } },
  backdrop = { part = 'BackgroundBlur_82', strength = 30.0 },
  -- With a list open, nav keys move the choice over the rows that show and run_key runs it. The game's
  -- own arrows count the rows the filter hid, and its Enter runs the list's own selection.
  nav = { UP_ARROW = -1, DOWN_ARROW = 1 },
  run_key = 'RETURN',
  -- What the panel's own label over the command line says (part: the game's name for that label; the
  -- game rewrites the line under the command line itself, so the hint cannot go there): text with no
  -- list open, listing while one is. filtering is the list's own line under its title, with {query}
  -- for what has been typed.
  hint = { part = 'CommonTextBlock_2',
    text = 'Type a command and press Enter, or pick a list. Esc closes.',
    listing = 'Typing filters the list below. Esc: back to the command line.',
    filtering = 'Filter: {query}_    {shown} of {all}    Up/Down choose, Enter runs, Esc back' },
  -- The panel is the game's own cheat panel. hide: kinds of part to hide. keep: part names that stay.
  panel = {
    hide = { 'CommonTextButton_C', 'CommonTextBlock', 'BackgroundBlur', 'HorizontalBox' },
    keep = { 'Input', 'autocomplete', 'Description', 'ItemButton', 'SpawnButton', 'EquipButton', 'MacroButton',
      'HistoryButton', 'HorizontalBox_0', 'CommonTextBlock_2' },
  },
  -- What closing also closes: the game's pick lists (by class; the game stacks them, so they are
  -- closed one after another, wait_ms apart, at most `most` of them) and, through the game's own
  -- commands, its diagnostic windows.
  -- modal: the game's own command that closes its top list. Only that undoes what the game set up when
  -- it opened the list; deactivating the list alone left the mouse with the game's menus, so the view
  -- no longer turned. A list still open after it is deactivated.
  close = { lists = { 'WBP_CheatListSelector_C' }, most = 100, wait_ms = 100, commands = { 'CloseDiag' },
    modal = 'HideModal' },
  -- After everything is closed: what the world needs back, each with the game's function that says it
  -- is still held and the one that lets it go.
  give_back = {
    { name = 'mouse look', held = '/Script/Engine.Controller:IsLookInputIgnored',
      release = '/Script/Engine.Controller:ResetIgnoreLookInput' },
    { name = 'movement', held = '/Script/Engine.Controller:IsMoveInputIgnored',
      release = '/Script/Engine.Controller:ResetIgnoreMoveInput' },
  },
  -- While one of the game's lists is open, the keyboard belongs to the list, not the command line, so
  -- this mod reads the typing keys itself (keys: UE4SS Key names, each with the character it types;
  -- erase: the key that takes one back) and hides the rows that do not answer what was typed. Items
  -- the game itself calls unpublished are hidden unless show_unpublished is true. Lists opening and
  -- closing are looked for every every_ms.
  -- strip: the parts of an item's data name that every item shares, as Lua patterns.
  -- live: false turns the search off altogether.
  -- settle_ms: how long a list's row count must hold still before its rows are read.
  search = { live = true, every_ms = 250, settle_ms = 500, show_unpublished = false,
    strip = { '^DA_', '_ItemType.*$' },
    keys = { A = 'a', B = 'b', C = 'c', D = 'd', E = 'e', F = 'f', G = 'g', H = 'h', I = 'i', J = 'j', K = 'k',
      L = 'l', M = 'm', N = 'n', O = 'o', P = 'p', Q = 'q', R = 'r', S = 's', T = 't', U = 'u', V = 'v',
      W = 'w', X = 'x', Y = 'y', Z = 'z', ZERO = '0', ONE = '1', TWO = '2', THREE = '3', FOUR = '4',
      FIVE = '5', SIX = '6', SEVEN = '7', EIGHT = '8', NINE = '9', SPACE = ' ', OEM_PERIOD = '.',
      OEM_MINUS = '-', OEM_COMMA = ',', OEM_TWO = '/' },
    erase = 'BACKSPACE',
    -- An item's category is the folder its data lives in (Tools, Resource, Equipment): typing it
    -- narrows the list. A Lua pattern over the item's full name.
    category = '/ItemType/([%w_]+)/' },
  -- What this mod says in UE4SS.log.
  log = {
    tag = '[MoonpoolConsole] ',
    ready = '{key} shows and closes the admin panel',
    bad_key = 'config.lua names a key UE4SS does not know: {key}',
    failed = '{what} failed {tries} times: {error}',
    missing = 'the game has no {what}',
    not_made = 'the game did not create the panel',
    error = 'the panel could not be shown or closed: {error}',
    gave_back = '{what} was still held after the panel closed; handed back to the game',
  },
  -- The game's own names this mod uses. They change only when the game does.
  game = {
    panel = '/Game/Blueprints/UI/Cheat/WBP_CheatInput.WBP_CheatInput_C',
    panel_class = 'WBP_CheatInput_C',
    server_cheat = 'SN2PlayerController:ServerCheat', -- named when sending a line fails
    typed = '/Script/Subnautica2.SN2CheatInput:GetTypedString',
    focus = '/Script/UMG.Widget:SetFocus',
    controller = 'PlayerController',
    template_prefix = 'Default__',      -- a class's own template object, never a live one
    -- Where the walk up the cheat manager's classes ends. Subnautica's own commands are sent on to the
    -- server by the game; the engine's (this class and above: DestroyAll, DestroyTarget, Summon) run
    -- only on the player's PC, where they change nothing, so they are not counted as the game's and
    -- go to the server's console like any other typed line.
    last_class = 'CheatManager',
    widgets = '/Script/UMG.Default__WidgetBlueprintLibrary',
    system = '/Script/Engine.Default__KismetSystemLibrary',
    set_visibility = '/Script/UMG.Widget:SetVisibility',
    set_text = '/Script/UMG.TextBlock:SetText',
    list_rows = 'ItemsList',            -- the part of a pick list that holds its rows
    row_item = 'Context',               -- what a row stands for: an item's name in the game's data
    tree = 'WidgetTree',                -- where a panel keeps its widgets
    root = 'RootWidget',                -- and the topmost of them
    container = '/Script/UMG.PanelWidget', -- the kind of widget that holds others
    child_count = '/Script/UMG.PanelWidget:GetChildrenCount',
    child_at = '/Script/UMG.PanelWidget:GetChildAt',
    item_class = 'UWEItemType',
    item_label = 'Name',
    is_published = '/Script/UWEAssetRegistry.UWEPrimaryDataAssetBase:IsPublished',
    -- The game counts an activated panel as an open menu, shown or not, and stops offering the
    -- world's own actions; so the panel is activated only while it shows.
    activate = '/Script/CommonUI.CommonActivatableWidget:ActivateWidget',
    deactivate = '/Script/CommonUI.CommonActivatableWidget:DeactivateWidget',
    is_activated = '/Script/CommonUI.CommonActivatableWidget:IsActivated',
    set_anchors = '/Script/UMG.CanvasPanelSlot:SetAnchors',
    set_alignment = '/Script/UMG.CanvasPanelSlot:SetAlignment',
    set_auto_size = '/Script/UMG.CanvasPanelSlot:SetAutoSize',
    set_offsets = '/Script/UMG.CanvasPanelSlot:SetOffsets',
    -- ESlateVisibility. Shown, the panel takes clicks only on its own parts (SelfHitTestInvisible):
    -- its backing covers the whole screen and would swallow clicks meant for the lists and the game.
    shown = 4,
    hidden = 1,
    row_shown = 0,                      -- a list row that shows takes clicks (Visible)
    layer = 1000,                       -- above the game's own screens
    set_tint = '/Script/UMG.Border:SetBrushColor',
    selectable = '/Script/CommonUI.CommonButtonBase:SetIsSelectable',
    select = '/Script/CommonUI.CommonButtonBase:SetIsSelected',
    list_model = 'SN2CheatListViewModel', -- what a pick list shows and runs
    pick = '/Script/Subnautica2.SN2CheatListViewModel:SelectItem',
    set_blur = '/Script/UMG.BackgroundBlur:SetBlurStrength',
  },
}
