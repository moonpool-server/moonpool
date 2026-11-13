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
  -- Where the panel sits: under the game's centred pick lists, as wide as they are, so the command
  -- line reads as the list's search box. From left to right as shares of the screen's width, standing on the line at
  -- bottom (a share of its height), with margins in the game's own layout units. part is the game's
  -- name for the block that holds the whole panel.
  layout = { part = 'VerticalBox_199', left = 0.409, right = 0.591, bottom = 0.93,
    margin = { left = 0.0, right = 0.0, bottom = 0.0 } },
  -- The panel is the game's own cheat panel. hide: kinds of part to hide. keep: part names that stay.
  panel = {
    hide = { 'CommonTextButton_C', 'CommonTextBlock', 'BackgroundBlur', 'HorizontalBox' },
    keep = { 'Input', 'autocomplete', 'Description', 'ItemButton', 'SpawnButton', 'EquipButton', 'MacroButton',
      'HistoryButton', 'HorizontalBox_0' },
  },
  -- What closing also closes: the game's pick lists (by class; the game stacks them, so they are
  -- closed one after another, wait_ms apart, at most `most` of them) and, through the game's own
  -- commands, its diagnostic windows.
  close = { lists = { 'WBP_CheatListSelector_C' }, most = 100, wait_ms = 100, commands = { 'CloseDiag' } },
  -- The command line is also a search box: while one of the game's lists is open, rows that do not
  -- answer what is typed are hidden (looked at every every_ms). Items the game itself calls
  -- unpublished are hidden unless show_unpublished is true.
  -- strip: the parts of an item's data name that every item shares, as Lua patterns.
  -- live: false turns the search off altogether.
  -- settle_ms: how long a list's row count must hold still before its rows are read.
  search = { live = true, every_ms = 250, settle_ms = 500, show_unpublished = false,
    strip = { '^DA_', '_ItemType.*$' },
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
  },
  -- The game's own names this mod uses. They change only when the game does.
  game = {
    panel = '/Game/Blueprints/UI/Cheat/WBP_CheatInput.WBP_CheatInput_C',
    panel_class = 'WBP_CheatInput_C',
    typed_line = '/Game/Blueprints/UI/Cheat/WBP_CheatInput.WBP_CheatInput_C:Exec',
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
    typed = '/Script/Subnautica2.SN2CheatInput:GetTypedString',
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
  },
}
