-- Settings for the admin console panel. Data only: edit and restart the game.
return {
  -- The key that shows the panel and, pressed again, closes it and everything it opened
  -- (a name from UE4SS's Key table).
  key = 'F2',
  -- The word the server's console listens for (signal_word in the server's console.json).
  word = 'mp',
  -- Calls into the game fail now and then on this build; each is tried this many times.
  tries = 40,
  -- Where the panel sits: from left to right as shares of the screen's width, standing on the line at
  -- bottom (a share of its height), with margins in the game's own layout units. part is the game's
  -- name for the block that holds the whole panel.
  layout = { part = 'VerticalBox_199', left = 0.66, right = 1.0, bottom = 1.0,
    margin = { left = 0.0, right = 24.0, bottom = 40.0 } },
  -- The panel is the game's own cheat panel. hide: kinds of part to hide. keep: part names that stay.
  panel = {
    hide = { 'CommonTextButton_C', 'CommonTextBlock', 'BackgroundBlur', 'HorizontalBox' },
    keep = { 'Input', 'autocomplete', 'Description', 'ItemButton', 'SpawnButton', 'EquipButton', 'GotoButton',
      'DiagNearby', 'HorizontalBox', 'HorizontalBox_0' },
  },
  -- What closing also closes: the game's pick lists (by class; the game stacks them, so they are
  -- closed one after another, wait_ms apart, at most `most` of them) and, through the game's own
  -- commands, its diagnostic windows.
  close = { lists = { 'WBP_CheatListSelector_C' }, most = 100, wait_ms = 100, commands = { 'CloseDiag' } },
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
    last_class = 'Object',              -- where the walk up the cheat manager's classes ends
    widgets = '/Script/UMG.Default__WidgetBlueprintLibrary',
    system = '/Script/Engine.Default__KismetSystemLibrary',
    set_visibility = '/Script/UMG.Widget:SetVisibility',
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
    layer = 1000,                       -- above the game's own screens
  },
}
