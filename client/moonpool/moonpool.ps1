#Requires -Version 5.1
<#
.SYNOPSIS
  Brings the local Subnautica 2 mods in line with what the server declares,
  then starts the game through Steam.

.DESCRIPTION
  Installed once from the project's releases, which its release key signs, and opened by a join page's
  moonpool: link. The server's own key signs its mod list; the mods are code that runs as you, and
  nothing here reviews them. It asks before installing anything a server names, verifies and places
  the mods the server's signed manifest declares (rolling all of it back on a failure, never removing
  a file it did not place), then starts the game through Steam. Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
  # A join page's link, moonpool:<address>. Windows hands it over from a web page, so it comes alone.
  [string]$Link,
  # A saved server's id (the shortcut), or a server's address.
  [string]$Server,
  # Install the launcher and its link handler for this Windows user.
  [switch]$Install,
  # For tests: a manifest address with no server behind it.
  [string]$ManifestUrl,
  # Steam's install folder; defaults to the one Steam records in the registry.
  [string]$SteamRoot,
  # For tests or a non-default Downloads folder.
  [string]$Downloads,
  # Optional mods to leave out (remembered per server), and ones to take back.
  [string[]]$Skip = @(),
  [string[]]$Keep = @(),
  # Let the server's copy replace a mod or loader already installed another way. Yours is
  # replaced, not kept: nothing puts it back later.
  [switch]$Adopt,
  # Turn off every file that makes Moonpool's mods load, then exit (the mods-off shortcut).
  [switch]$DisableMoonpoolMods,
  # Remove what Moonpool put on this PC that is still as it placed it, and say what stayed.
  [switch]$Uninstall,
  # For tests: no Desktop or Start menu shortcuts.
  [switch]$NoShortcuts,
  # For tests: how long the game may take to appear after the launch, and a smaller unpack limit.
  [int]$StartWait = 180,
  [long]$UnpackLimit = 0,
  # For tests: replace the running-game check, the launch and the pages opened.
  [scriptblock]$IsGameRunning,
  [scriptblock]$Launch,
  [scriptblock]$OpenFriend,
  [scriptblock]$OpenPage,
  [scriptblock]$Approve,
  [scriptblock]$ScanFile
)
$BoundCount = $PSBoundParameters.Count
$AllowLocal = [bool]$ManifestUrl -or $Server -like 'file:*'

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$GameProcessNames = @('Subnautica2-Win64-Test', 'Subnautica2-Win64-Shipping')
$DefaultAppId = '1962700'
$TrioExtensions = @('.pak', '.ucas', '.utoc')
$LoaderConfig = @('ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt', 'ue4ss\Mods\mods.json')
$script:Work = $null
$script:ModsOn = $false
$script:Lock = $null
$script:FirstWindowShown = $false
# The release job stamps its run number here; an update must be a higher one, so no rollback.
$LauncherBuild = 0
# The project's release key. Its private half is not on GitHub, so control of the account or a
# release is not enough to change this launcher script on a player's PC. The setup file is not
# signed, and what a server installs (its mods, the UE4SS loader) is held to the server's own key.
$ReleaseKey = @{ modulus = 'tSJdxcTDEY2AmF7xE0F5YN4V5XWk3nwuMlH5QXoVf4IgLuHVCl12SajOCwcWxS5wluItvHzJnprs01Gq5FY3/wLNPhQa5YIVsV9b1RzoybzR8s8fkzGaadANmcRQm39RMafxQppjeg5UP8jh1BHqNZvxTVQBAvBjWRI3tfJe8uqcoL6HAPdUM1xb8xc+pkb2E2UFcxGlcbrYMmRBrzjGLgTcye17gTo7bja0gjIa3/8kPG7ECwoH7MYhVKzJm8SdRSfz09lqbLtFfEG86/UBxoDPIhaLz+iYLx/gdsy9lpD78P3gN250cu2IcZE0/xmeyQSggfHOVuvNSWTQkyEsQwhYnF5HnZXnDNEg4mCqh2o/v06EljAe2JOrVZPiEoqT52uXtRh6prF6OmAoVidxS2FUVnIs2DGQDMf/RGM6GVXPd4bgqeXZGvjp8noklRk1qIE32i4RzHYsS3iD/UiHrfiXZacJ7DKWaN8FyVGXJFduyVYxZbmvE9XAl7LPFmwf'; exponent = 'AQAB' }
$KitHome = Join-Path $env:LOCALAPPDATA 'moonpool'
$script:ServerId = ''  # the server this run installs for, once known
$InstalledScript = Join-Path $KitHome 'moonpool.ps1'
# Forks change this one line and the same one in moonpool-setup.cmd.
$ReleaseBase = 'https://github.com/moonpool-server/moonpool/releases/latest/download'
$MaxUnpackedBytes = 4GB
if ($UnpackLimit -gt 0) { $MaxUnpackedBytes = $UnpackLimit }
$MaxArchiveEntries = 20000

# Every line is also kept in %LOCALAPPDATA%\moonpool\moonpool.log, so a player can send it to the host;
# past 1 MB the log starts over and the previous one is kept as moonpool.log.prev.
function Write-Log([string]$Message) {
  try {
    $log = Join-Path $KitHome 'moonpool.log'
    if (-not (Test-Path -LiteralPath $KitHome)) { New-Item -ItemType Directory -Path $KitHome -Force | Out-Null }
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) { Move-Item -LiteralPath $log -Destination "$log.prev" -Force }
    Add-Content -LiteralPath $log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " [build $LauncherBuild] $Message") -Encoding UTF8
  } catch { }
}

function Say([string]$Message) {
  Write-Host "moonpool: $Message"
  Write-Log $Message
  if ($script:Ui) { Set-Status ($Message.Substring(0, 1).ToUpperInvariant() + $Message.Substring(1)) }
}

# The one window a player sees, from the click to the game starting: what is happening with a bar,
# and every question and failure inside it, never a separate box. Windows' own forms, because this
# launcher is one signed file. A test or console run has none.
$script:Ui = $null
$script:UiCancelled = $false
$script:UiInstalling = $false
$script:UiClosed = $false
$script:UiAnswer = $null
$script:UiMode = 'progress'
$script:UiStep = 0
$script:UiSteps = 0
$Theme = @{ Back = '#0C2835'; Head = '#071923'; Text = '#EAF7FB'; Muted = '#9FB9C3'; Accent = '#39B7D5'; AccentText = '#04141C'; Line = '#286174'; Panel = '#0A2230' }
function Get-Color([string]$Hex) { [Drawing.ColorTranslator]::FromHtml($Hex) }

function New-UiLabel([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Font, [float]$Size, [string]$Color) {
  $l = New-Object Windows.Forms.Label
  $l.Location = New-Object Drawing.Point $X, $Y
  $l.Size = New-Object Drawing.Size $W, $H
  $l.Font = New-Object Drawing.Font $Font, $Size
  $l.ForeColor = Get-Color $Color
  $l.BackColor = [Drawing.Color]::Transparent
  $l.AutoEllipsis = $true
  return $l
}

function New-UiButton([string]$Text, [bool]$Primary, [int]$X) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $Text
  $b.FlatStyle = 'Flat'
  $b.Font = New-Object Drawing.Font 'Segoe UI Semibold', 10
  $b.Location = New-Object Drawing.Point $X, 262
  $b.Size = New-Object Drawing.Size 160, 38
  $b.Cursor = [Windows.Forms.Cursors]::Hand
  if ($Primary) {
    $b.BackColor = Get-Color $Theme.Accent; $b.ForeColor = Get-Color $Theme.AccentText; $b.FlatAppearance.BorderSize = 0
  } else {
    $b.BackColor = Get-Color $Theme.Back; $b.ForeColor = Get-Color $Theme.Text; $b.FlatAppearance.BorderColor = Get-Color $Theme.Line
  }
  return $b
}

# A porthole mark drawn here, so the window and the taskbar show Moonpool, not a blank form.
function New-UiIcon {
  $bmp = New-Object Drawing.Bitmap 64, 64
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.Clear([Drawing.Color]::Transparent)
  $g.FillEllipse((New-Object Drawing.SolidBrush (Get-Color $Theme.Accent)), 2, 2, 60, 60)
  $g.FillEllipse((New-Object Drawing.SolidBrush (Get-Color $Theme.Head)), 13, 13, 38, 38)
  $g.FillEllipse((New-Object Drawing.SolidBrush (Get-Color $Theme.Accent)), 24, 24, 16, 16)
  $g.Dispose()
  return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Open-Window {
  if ($script:Ui -or -not ($Link -or $Server -or $Uninstall -or $DisableMoonpoolMods) -or $env:SN2_JOIN_NO_DIALOG -or -not [Environment]::UserInteractive) { return }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Moonpool'
    $form.ClientSize = New-Object Drawing.Size 560, 320
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.BackColor = Get-Color $Theme.Back
    $form.ForeColor = Get-Color $Theme.Text
    try { $form.Icon = New-UiIcon } catch { }
    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'
    $head.Height = 66
    $head.BackColor = Get-Color $Theme.Head
    $title = New-UiLabel 22 10 516 28 'Segoe UI Semibold' 15 $Theme.Text
    $title.Text = 'Moonpool'
    $sub = New-UiLabel 23 39 516 20 'Segoe UI' 9.5 $Theme.Muted
    $sub.Text = 'Subnautica 2 mods for this server'
    $head.Controls.AddRange(@($title, $sub))
    $heading = New-UiLabel 22 86 516 52 'Segoe UI Semibold' 12 $Theme.Text
    $heading.AutoEllipsis = $false
    $heading.Text = 'Getting ready'
    $detail = New-UiLabel 23 142 516 44 'Segoe UI' 9.5 $Theme.Muted
    $detail.AutoEllipsis = $false
    $detail.Text = "Moonpool checks this server's mods, installs or updates them, turns them on for this game session only, then starts Subnautica 2 through Steam."
    $bar = New-Object Windows.Forms.Panel
    $bar.Location = New-Object Drawing.Point 22, 204
    $bar.Size = New-Object Drawing.Size 516, 8
    $bar.BackColor = Get-Color $Theme.Line
    $fill = New-Object Windows.Forms.Panel
    $fill.BackColor = Get-Color $Theme.Accent
    $fill.Size = New-Object Drawing.Size 120, 8
    $bar.Controls.Add($fill)
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 30
    $timer.add_Tick({
      $f = $script:Ui.Fill
      $x = $f.Left + 8
      if ($x -gt $script:Ui.Bar.Width) { $x = -$f.Width }
      $f.Left = $x
    })
    # The text sits in a padded panel; the panel grows with the text and the window with it.
    $pane = New-Object Windows.Forms.Panel
    $pane.Location = New-Object Drawing.Point 22, 126
    $pane.Size = New-Object Drawing.Size 516, 120
    $pane.BackColor = Get-Color $Theme.Panel
    $pane.Visible = $false
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'None'
    $box.BorderStyle = 'None'
    $box.BackColor = Get-Color $Theme.Panel
    $box.ForeColor = Get-Color $Theme.Text
    $box.Font = New-Object Drawing.Font 'Segoe UI', 10
    $box.Location = New-Object Drawing.Point 14, 12
    $box.Size = New-Object Drawing.Size 492, 96
    $box.TabStop = $false
    $pane.Controls.Add($box)
    $primary = New-UiButton 'OK' $true 378
    $primary.Visible = $false
    $secondary = New-UiButton 'Cancel' $false 378
    $form.Controls.AddRange(@($head, $heading, $detail, $bar, $pane, $primary, $secondary))
    $primary.add_Click({ $script:UiAnswer = $true })
    $secondary.add_Click({
      if ($script:UiMode -eq 'ask') { $script:UiAnswer = $false }
      elseif (-not $script:UiInstalling) { $script:UiCancelled = $true; $script:Ui.Heading.Text = 'Cancelling'; $script:Ui.Secondary.Enabled = $false }
    })
    # Closing cancels while nothing is placed. Once files are moving it waits: they finish or are put back.
    $form.add_FormClosing({ param($s, $e)
      if ($script:UiInstalling) { $e.Cancel = $true; return }
      $script:UiCancelled = $true
      if ($script:UiMode -eq 'ask') { $script:UiAnswer = $false }
    })
    $form.add_FormClosed({ $script:UiClosed = $true })
    $form.Show()
    $form.Activate()
    [Windows.Forms.Application]::DoEvents()
    $script:Ui = @{ Form = $form; Sub = $sub; Heading = $heading; Detail = $detail; Bar = $bar; Fill = $fill; Timer = $timer; Pane = $pane; Box = $box; Primary = $primary; Secondary = $secondary }
    $timer.Start()
  } catch { $script:Ui = $null }
}

# progress: heading, detail, bar and Cancel; ask and notice: heading, a text panel and buttons.
function Set-UiMode([string]$Mode, [string]$Text = '') {
  $ui = $script:Ui
  $script:UiMode = $Mode
  $working = $Mode -eq 'progress'
  $ui.Detail.Visible = $working
  $ui.Bar.Visible = $working
  $ui.Pane.Visible = -not $working
  $ui.Primary.Visible = -not $working
  $ui.Secondary.Visible = $Mode -ne 'notice'
  $ui.Secondary.Enabled = $true
  $height = 320
  if (-not $working) {
    $ui.Box.Text = $Text -replace "`r?`n", "`r`n"
    $ui.Box.SelectionLength = 0
    # Tall enough for the text up to a limit, with a scroll bar only past it.
    $flags = [Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::TextBoxControl
    $need = [Windows.Forms.TextRenderer]::MeasureText($ui.Box.Text, $ui.Box.Font, (New-Object Drawing.Size ($ui.Box.Width - 4), 0), $flags).Height + 6
    $max = 380
    $ui.Box.ScrollBars = if ($need -gt $max) { 'Vertical' } else { 'None' }
    $ui.Box.Height = [Math]::Max(40, [Math]::Min($need, $max))
    $ui.Pane.Height = $ui.Box.Height + 24
    $height = $ui.Pane.Top + $ui.Pane.Height + 76
  }
  $ui.Form.ClientSize = New-Object Drawing.Size 560, $height
  $y = $height - 58
  $ui.Primary.Location = New-Object Drawing.Point 378, $y
  if ($working) { $ui.Secondary.Text = 'Cancel'; $ui.Secondary.Location = New-Object Drawing.Point 378, $y }
  else { $ui.Secondary.Location = New-Object Drawing.Point 206, $y }
}

function Set-UiServer([string]$Name) {
  if ($script:Ui -and $Name) { $script:Ui.Sub.Text = "Joining $Name" }
}

# Percent is 0-100; below 0 the bar just moves, for a step with no known length.
function Set-Status([string]$Text, [int]$Percent = -1) {
  if (-not $script:Ui) { return }
  if ($script:UiCancelled) {
    $script:UiCancelled = $false
    Close-Window
    Fail 'you closed the window; nothing changed, game not started' 3
  }
  if ($Text) { $script:Ui.Heading.Text = $Text }
  $script:Ui.Secondary.Enabled = -not $script:UiInstalling
  if ($Percent -ge 0) {
    $script:Ui.Timer.Stop()
    $script:Ui.Fill.Left = 0
    $script:Ui.Fill.Width = [int]($script:Ui.Bar.Width * [Math]::Min(100, $Percent) / 100)
  }
  [Windows.Forms.Application]::DoEvents()
}

function Close-Window {
  if (-not $script:Ui) { return }
  $form = $script:Ui.Form
  $script:UiTimer = $script:Ui.Timer
  $script:Ui = $null
  $script:UiInstalling = $false
  try { $script:UiTimer.Stop() } catch { }
  try { $form.Close(); $form.Dispose() } catch { }
}

# Until a button is pressed or the window is closed.
function Wait-UiAnswer {
  $script:UiAnswer = $null
  $script:Ui.Form.Activate()
  while ($null -eq $script:UiAnswer -and -not $script:UiClosed) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 25
  }
  return [bool]$script:UiAnswer
}

# A yes or no inside the window. Closing the window is a no.
function Show-Question([string]$Text, [string]$Heading = 'Before you continue', [string]$Yes = 'Yes', [string]$No = 'No') {
  if (-not $script:Ui -or $script:UiClosed) {
    Add-Type -AssemblyName System.Windows.Forms
    return [Windows.Forms.MessageBox]::Show($Text, 'Moonpool', 'YesNo', 'Question', 'Button2') -eq 'Yes'
  }
  $ui = $script:Ui
  # The heading already asks, so a closing one-word question in the text is dropped.
  Set-UiMode 'ask' ($Text -replace '\s*Install\?\s*$', '')
  $ui.Heading.Text = $Heading
  $ui.Primary.Text = $Yes
  $ui.Secondary.Text = $No
  $yes = Wait-UiAnswer
  if ($script:Ui -and -not $script:UiClosed) { Set-UiMode 'progress' }
  if ($yes) { $script:UiCancelled = $false }
  return $yes
}

# The server's mods with a box each: required ones ticked and locked, optional ones as the player
# last chose (or as the host set them, the first time). Install and play is the answer to installing
# what is ticked; Cancel or closing the window declines. Returns the optional mods left out.
function Show-ModPicker($All, $Skipped, $Config, [string]$ServerId, $LoaderSpec) {
  $ui = $script:Ui
  $accepted = @(Read-Json (Join-Path $KitHome "$ServerId\accepted.json") @())
  $acceptedNames = @($accepted | ForEach-Object { ([string]$_ -split '\|')[0] })
  $name = [string](Get-Prop $Config 'server_name' 'this server')
  Set-UiMode 'ask' ' '
  $ui.Box.Visible = $false
  $flow = New-Object Windows.Forms.FlowLayoutPanel
  $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
  $flow.Location = New-Object Drawing.Point 14, 10
  $flow.BackColor = Get-Color $Theme.Panel
  $boxes = @{}
  foreach ($m in $All) {
    $cb = New-Object Windows.Forms.CheckBox
    $cb.AutoSize = $true
    $cb.Font = New-Object Drawing.Font 'Segoe UI', 10
    $cb.ForeColor = Get-Color $Theme.Text
    $cb.Margin = New-Object Windows.Forms.Padding 0, 3, 0, 3
    $tags = @(Get-ModHost $m); if ($m.Native) { $tags += 'native code' }; if ($m.Required) { $tags += 'required' }
    if ($accepted -notcontains (Get-CodeSet @($m) $null)[0]) { if ($acceptedNames -contains $m.Name) { $tags += 'changed' } else { $tags += 'new' } }
    $cb.Text = ("$($m.Name) $($m.Version)").Trim() + '   (' + ($tags -join ', ') + ')'
    $cb.Checked = $m.Required -or -not $Skipped.Contains($m.Name)
    if ($m.Required) { $cb.AutoCheck = $false }  # always installed: shown ticked and readable, not greyed out
    [void]$flow.Controls.Add($cb)
    $boxes[$m.Name] = $cb
  }
  if ($LoaderSpec) {  # the prerequisite the UE4SS mods need, listed with them so nothing installs unseen
    $cb = New-Object Windows.Forms.CheckBox
    $cb.AutoSize = $true; $cb.Checked = $true; $cb.AutoCheck = $false
    $cb.Font = New-Object Drawing.Font 'Segoe UI', 10
    $cb.ForeColor = Get-Color $Theme.Text
    $cb.Margin = New-Object Windows.Forms.Padding 0, 3, 0, 3
    $cb.Text = 'UE4SS loader   (this server, native code, needed by the UE4SS mods)'
    [void]$flow.Controls.Add($cb)
  }
  $flow.Size = New-Object Drawing.Size 492, ([Math]::Min(30 * $flow.Controls.Count + 4, 240))
  $noteText = (Get-KeyWarning $Config $ServerId) + "Ticked mods are installed and turned on for this game session only. They run with your Windows account's rights, so only install mods from a host you trust."
  if ($LoaderSpec) {
    $noteText += ' UE4SS mods also need the UE4SS loader, from this server, native code'
    $loaderLine = @(Get-CodeSet @() $LoaderSpec)[0]
    if ($accepted -notcontains $loaderLine) { $noteText += " ($(Get-Prop $LoaderSpec 'asset' ''), " + $(if ($acceptedNames -contains 'UE4SS loader') { 'changed' } else { 'new' }) + ')' }
    $noteText += '.'
  }
  $noteText += "`n`nServer: $([string](Get-Prop $Config 'address' ''))"
  $note = New-UiLabel 14 0 492 10 'Segoe UI' 9.5 $Theme.Muted
  $note.AutoEllipsis = $false
  $note.Text = $noteText
  $note.Height = [Windows.Forms.TextRenderer]::MeasureText($noteText, $note.Font, (New-Object Drawing.Size 488, 0), [Windows.Forms.TextFormatFlags]::WordBreak).Height + 4
  $note.Top = $flow.Bottom + 8
  $ui.Pane.Controls.AddRange(@($flow, $note))
  $ui.Pane.Height = $note.Bottom + 12
  $height = $ui.Pane.Top + $ui.Pane.Height + 76
  $ui.Form.ClientSize = New-Object Drawing.Size 560, $height
  $ui.Primary.Location = New-Object Drawing.Point 378, ($height - 58)
  $ui.Secondary.Location = New-Object Drawing.Point 206, ($height - 58)
  $ui.Heading.Text = "Install mods from ${name}?"
  $ui.Primary.Text = 'Install and play'
  $ui.Secondary.Text = 'Cancel'
  $yes = Wait-UiAnswer
  if (-not $yes) { Fail 'you declined; nothing changed, game not started. The join page can join without mods.' 3 }
  $left = New-Object System.Collections.Generic.List[string]
  foreach ($m in $All) { if (-not $m.Required -and -not $boxes[$m.Name].Checked) { $left.Add($m.Name) } }
  $ui.Pane.Controls.Remove($flow); $ui.Pane.Controls.Remove($note)
  $ui.Box.Visible = $true
  Set-UiMode 'progress'
  $script:UiCancelled = $false
  return ,$left
}

# A message the player reads once and closes: a failure, or what an uninstall did.
function Show-Notice([string]$Heading, [string]$Text) {
  if ($Text) { $Text = $Text.Substring(0, 1).ToUpperInvariant() + $Text.Substring(1) }
  if ($script:UiClosed) { return }
  Open-Window
  if (-not $script:Ui) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show("$Heading`n`n$Text", 'Moonpool')
    return
  }
  $script:UiInstalling = $false
  # A failure can arrive while the mod list is on screen: take the list away and bring the text box back.
  foreach ($c in @($script:Ui.Pane.Controls)) { if ($c -ne $script:Ui.Box) { $script:Ui.Pane.Controls.Remove($c) } }
  $script:Ui.Box.Visible = $true
  Set-UiMode 'notice' $Text
  $script:Ui.Heading.Text = $Heading
  $script:Ui.Primary.Text = 'Close'
  [void](Wait-UiAnswer)
}

# A failure the player should read as one plain line.
function Fail([string]$Message, [int]$Code = 1) {
  $e = New-Object System.Exception $Message
  $e.Data['sn2code'] = $Code
  throw $e
}

function Get-Prop($Object, [string]$Name, $Default) {
  if ($null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)) { return $Object.$Name }
  return $Default
}

# https, or plain http only inside a private network: the address decides whose mods are offered.
function Test-ServerAddress([string]$Address) {
  if ($Address -notmatch '^https?://[A-Za-z0-9.:\[\]-]+(/[A-Za-z0-9._~/-]*)?$') { return $false }
  if ($Address -match '^https://') { return $true }
  $name = ([Uri]$Address).DnsSafeHost
  if ($name -eq 'localhost') { return $true }
  $ip = $null
  if (-not [Net.IPAddress]::TryParse($name, [ref]$ip)) { return $false }
  if ($ip.AddressFamily -eq 'InterNetworkV6') { return ($ip.IsIPv6LinkLocal -or $ip.IsIPv6SiteLocal -or [Net.IPAddress]::IsLoopback($ip) -or ($ip.GetAddressBytes()[0] -band 0xfe) -eq 0xfc) }
  $b = $ip.GetAddressBytes()
  return ($b[0] -eq 10 -or $b[0] -eq 127 -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 169 -and $b[1] -eq 254))
}

# The folder name for a server comes from its key, worked out here: what a server says about
# itself never becomes a path, and a new key is a new server to ask about.
function Get-ServerId($Config) {
  $key = [BitConverter]::ToString([Convert]::FromBase64String([string]$Config.public_key.modulus)) + ':' + [BitConverter]::ToString([Convert]::FromBase64String([string]$Config.public_key.exponent))
  $bytes = [Text.Encoding]::UTF8.GetBytes($key)
  $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
  return (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function Read-ServerConfig([string]$Address) {
  $file = Join-Path ([IO.Path]::GetTempPath()) ('moonpool-config-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    Save-Url "$($Address.TrimEnd('/'))/moonpool.json" $file
    $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  } catch { Fail "could not read the server at ${Address}: $($_.Exception.Message)" }
  finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
  if (-not (Get-Prop (Get-Prop $config 'public_key' $null) 'modulus' '')) { Fail "the server at $Address has no signing key" }
  $config | Add-Member -Force address $Address.TrimEnd('/')
  return $config
}

# The one question: anything this server's list would add or change that the player has not
# accepted. Removals need no answer. A manual -Server or a shortcut asks the same way.
function Confirm-CodeSet($Config, [string]$ServerId, [string[]]$Lines) {
  $path = Join-Path $KitHome "$ServerId\accepted.json"
  $accepted = @(Read-Json $path @())
  $new = @($Lines | Where-Object { $accepted -notcontains $_ })
  if ($new.Count -gt 0) {
    $name = [string](Get-Prop $Config 'server_name' 'this server')
    $where = [string](Get-Prop $Config 'address' '')
    $text = "$name wants to install these on this PC:`n`n" +
      (($new | ForEach-Object {
        $p = $_ -split '\|'
        $label = [string]$p[0]
        if ($label -ne 'UE4SS loader' -and $p[1]) { $label += " $($p[1])" }
        $kind = if ($p[-1] -eq 'native code') { ', native code' } else { '' }
        "  - $label from $($p[-2])$kind"
      }) -join "`n") +
      "`n`nThese run with your Windows account's rights, so only say yes to a host you trust. " +
      "They are on only until the game this starts closes, and Moonpool never turns off your own mods.`n`nServer: $where`n`nInstall?"
    $text = (Get-KeyWarning $Config $ServerId) + $text
    if ($Approve) { $yes = & $Approve $text } else { $yes = Show-Question $text "Install mods from ${name}?" 'Install and play' 'Cancel' }
    if (-not $yes) { Fail 'you declined; nothing changed, game not started. The join page can join without mods.' 3 }
  }
  Write-Json $path @($Lines)
}

# Said first whenever this address answered with another server key before.
function Get-KeyWarning($Config, [string]$ServerId) {
  $where = [string](Get-Prop $Config 'address' '')
  $known = @(Get-ChildItem -LiteralPath $KitHome -Filter 'moonpool.json' -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.Directory.Name -ne $ServerId -and (Get-Prop (Read-Json $_.FullName $null) 'address' '') -eq $where })
  if ($where -and $known) { return "WARNING: this address had a different server key before. It may not be the same server.`n`n" }
  return ''
}

# Where a mod's file really downloads from; the page only for a file the player fetches by hand.
function Get-ModHost($Mod) {
  $from = [string](Get-Prop $Mod.Source 'url' ''); if (-not $from) { $from = [string](Get-Prop $Mod.Source 'page' '') }
  if (-not $from) { return 'this server' }
  try {
    $at = [Uri](Resolve-Url $ManifestUrl $from)
    if ($at.Scheme -notmatch '^https?$') { return 'this server' }
    if ($from -notmatch '^\s*https?:' -and $at.Host -eq ([Uri]$ManifestUrl).Host) { return 'this server' }
    return $at.Host
  } catch {
    $at = $null
    if ([Uri]::TryCreate($from, [UriKind]::Absolute, [ref]$at) -and $at.Scheme -match '^https?$') { return $at.Host }
    return 'this server'
  }
}

# Every field that decides what runs, one line per mod and the loader, so changing any of them asks again.
function Get-CodeSet($Wanted, $LoaderSpec) {
  $lines = @($Wanted | ForEach-Object {
    "$($_.Name)|$($_.Version)|$(@(Get-Prop $_.Source 'hashes' @()) | ForEach-Object { "$($_.algorithm):$($_.value)" })|$($_.Identity)|$(Get-ModHost $_)|$(if ($_.Native) { 'native code' } else { 'scripts' })" })
  if ($LoaderSpec) { $lines += "UE4SS loader|$(Get-Prop $LoaderSpec 'asset' '')|sha256:$(Get-Prop $LoaderSpec 'sha256' '')|$(@(Get-Prop $LoaderSpec 'allowed_builds' @()) -join ',')|this server|native code" }
  return ,$lines
}

function Test-GameRunning {
  if ($IsGameRunning) { return [bool](& $IsGameRunning) }
  foreach ($n in $GameProcessNames) {
    if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
  }
  return $false
}

function Get-DefaultSteamRoot {
  $reg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue
  if ($reg -and $reg.SteamPath) { return ($reg.SteamPath -replace '/', '\') }
  return (Join-Path ${env:ProgramFiles(x86)} 'Steam')
}

function Get-SteamLibraries([string]$Root) {
  $libs = New-Object System.Collections.Generic.List[string]
  $libs.Add($Root)
  $vdf = Join-Path $Root 'steamapps\libraryfolders.vdf'
  if (Test-Path -LiteralPath $vdf) {
    $text = Get-Content -LiteralPath $vdf -Raw
    foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
      $p = $m.Groups[1].Value -replace '\\\\', '\'
      if (-not ($libs -contains $p)) { $libs.Add($p) }
    }
  }
  return $libs
}

function Find-AppManifest([string]$Root, [string]$AppId) {
  foreach ($lib in (Get-SteamLibraries $Root)) {
    $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
    if (Test-Path -LiteralPath $acf) { return $acf }
  }
  return $null
}

function Get-AcfValue([string]$Path, [string]$Name) {
  $m = [regex]::Match((Get-Content -LiteralPath $Path -Raw), '"' + [regex]::Escape($Name) + '"\s+"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Find-GameFolder([string]$Root, [string]$AppId) {
  $libs = Get-SteamLibraries $Root
  foreach ($lib in $libs) {
    $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
    if (-not (Test-Path -LiteralPath $acf)) { continue }
    $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
    if (-not $m.Success) { continue }
    $dir = Join-Path $lib ("steamapps\common\" + $m.Groups[1].Value)
    if (Test-Path -LiteralPath $dir) { return $dir }
  }
  Fail ("Subnautica 2 (app $AppId) is not installed in any Steam library; looked in: " + ($libs -join '; '))
}

function ConvertTo-LocalPath([string]$Url) {
  if ($Url -like 'file:*') { return ([Uri]$Url).LocalPath }
  return $Url
}

function Use-Tls12 {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Resolve-Url([string]$Base, [string]$Value) {
  return (New-Object Uri([Uri]$Base, $Value)).AbsoluteUri
}

function Save-Url([string]$Url, [string]$Dest) {
  if ($Url -match '^https?://') {
    Use-Tls12
    $request = [Net.WebRequest]::Create($Url)
    $request.UserAgent = 'moonpool launcher'
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $response = $request.GetResponse()
    try {
      $in = $response.GetResponseStream()
      $out = [IO.File]::Create($Dest)
      try {
        $buffer = New-Object byte[] 65536
        $got = [long]0
        $shown = [DateTime]::UtcNow
        while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
          $out.Write($buffer, 0, $n)
          $got += $n
          if ($script:Ui -and $script:UiSteps -gt 0 -and ([DateTime]::UtcNow - $shown).TotalMilliseconds -gt 100) {
            $part = 0.0
            if ($response.ContentLength -gt 0) { $part = [double]$got / $response.ContentLength }
            Set-Status '' ([int](100 * (($script:UiStep - 1 + $part) / $script:UiSteps)))
            $shown = [DateTime]::UtcNow
          }
        }
      } finally { $out.Dispose(); $in.Dispose() }
    } finally { $response.Close() }
  } else {
    # Local paths are for tests only: a server's file: address could reach a network share.
    if (-not ($script:AllowLocal -or $env:SN2_JOIN_UPDATE_URL)) { throw "not a web address: $Url" }
    Copy-Item -LiteralPath (ConvertTo-LocalPath $Url) -Destination $Dest
  }
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-ManifestSignature([string]$ManifestPath, [string]$SignaturePath, $PublicKey) {
  try {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.ImportParameters([Security.Cryptography.RSAParameters]@{
      Modulus = [Convert]::FromBase64String([string]$PublicKey.modulus)
      Exponent = [Convert]::FromBase64String([string]$PublicKey.exponent)
    })
    return $rsa.VerifyData([IO.File]::ReadAllBytes($ManifestPath),
      [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'), [IO.File]::ReadAllBytes($SignaturePath))
  } catch { return $false }
}

# Every hash the manifest lists for a file must match (sha256, sha1 or md5).
function Test-Hashes([string]$Path, $Hashes) {
  foreach ($expected in @($Hashes)) {
    $algorithm = ([string](Get-Prop $expected 'algorithm' '')).ToUpperInvariant()
    if ($algorithm -notin @('SHA256', 'SHA1', 'MD5')) { return "unsupported hash $algorithm" }
    $want = ([string](Get-Prop $expected 'value' '')).ToLowerInvariant()
    $got = (Get-FileHash -Algorithm $algorithm -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($got -ne $want) { return "failed its $($algorithm.ToLowerInvariant()) check (expected $want, got $got)" }
  }
  return $null
}

function Get-DownloadsFolder {
  if ($Downloads) { return $Downloads }
  try {
    $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
    if ($p) { return $p }
  } catch { }
  return (Join-Path $env:USERPROFILE 'Downloads')
}

# conhost --headless runs PowerShell with no window, whichever terminal Windows defaults to.
function Get-HiddenRun {
  $conhost = "$env:SystemRoot\System32\conhost.exe"
  $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  if (Test-Path -LiteralPath $conhost) { return @{ Exe = $conhost; Prefix = "--headless `"$ps`" " } }
  return @{ Exe = $ps; Prefix = '' }
}

# A test run points these at scratch places, so it never touches the user's own.
function Get-HandlerKey { if ($env:MOONPOOL_CLASSES_ROOT) { Join-Path $env:MOONPOOL_CLASSES_ROOT 'moonpool' } else { 'HKCU:\Software\Classes\moonpool' } }
function Get-ShortcutFolders {
  if ($env:MOONPOOL_SHORTCUTS) { return @((Join-Path $env:MOONPOOL_SHORTCUTS 'Desktop'), (Join-Path $env:MOONPOOL_SHORTCUTS 'Programs')) }
  return @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
}

function Install-Launcher {
  New-Item -ItemType Directory -Path $KitHome -Force | Out-Null
  if ([IO.Path]::GetFullPath($PSCommandPath) -ine [IO.Path]::GetFullPath($InstalledScript)) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force
  }
  if ($NoShortcuts) { return }
  $key = Get-HandlerKey
  New-Item -Path "$key\shell\open\command" -Force | Out-Null
  Set-ItemProperty -LiteralPath $key -Name '(default)' -Value 'URL:Subnautica 2 server'
  Set-ItemProperty -LiteralPath $key -Name 'URL Protocol' -Value ''
  # The name a browser shows when it asks to open the link; without it Windows names conhost.
  Set-ItemProperty -LiteralPath "$key\shell\open" -Name 'FriendlyAppName' -Value 'Moonpool'
  $run = Get-HiddenRun
  Set-ItemProperty -LiteralPath "$key\shell\open\command" -Name '(default)' -Value "`"$($run.Exe)`" $($run.Prefix)-NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" -Link `"%1`""
}

function Install-ServerShortcuts($Config, [string]$ServerId, [string]$Game = '') {
  $dir = Join-Path $KitHome $ServerId
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Write-Json (Join-Path $dir 'moonpool.json') $Config
  $firstRun = -not (Test-Path -LiteralPath (Join-Path $dir '.first-run-complete'))
  $server = [string](Get-Prop $Config 'server_name' 'server') -replace '[\\/:*?"<>|\x00-\x1f]', '_'
  $folders = @(Get-ShortcutFolders)
  if ($NoShortcuts) { $folders = @() }
  # The game's own icon, so a shortcut looks like Subnautica 2 rather than a PowerShell script.
  $icon = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
  if ($Game -and (Test-Path -LiteralPath (Join-Path $Game 'Subnautica2.exe'))) { $icon = (Join-Path $Game 'Subnautica2.exe') + ',0' }
  foreach ($folder in $folders) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $links = @{ "Subnautica 2 ($server)" = "-Server $ServerId" }
    if ($folder -eq $folders[0]) { $links['Subnautica 2 (without Moonpool mods)'] = '-DisableMoonpoolMods' }
    foreach ($name in $links.Keys) {
      $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $folder "$name.lnk"))
      $run = Get-HiddenRun
      $shortcut.TargetPath = $run.Exe
      $shortcut.Arguments = "$($run.Prefix)-NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" $($links[$name])"
      $shortcut.IconLocation = $icon
      $shortcut.WorkingDirectory = $KitHome
      $shortcut.Save()
    }
  }
  if ($folders.Count -gt 0) { Say "installed shortcuts for Subnautica 2 ($server)" }
  if ($firstRun) {
    $hostSteamId = [string](Get-Prop $Config 'host_steamid' '')
    if ($hostSteamId -match '^7656119[0-9]{10}$') {
      $friendUrl = "steam://friends/add/$hostSteamId"
      Say "opening the host's Steam profile once so you can send the friend request used to join"
      if ($OpenFriend) { & $OpenFriend $friendUrl } else { Start-Process $friendUrl }
    }
    Say "turn on background audio in the game's audio settings so voice keeps playing when you alt-tab"
    New-Item -ItemType File -Path (Join-Path $dir '.first-run-complete') -Force | Out-Null
  }
}

# ---- the one ledger: every local file this launcher manages, for every server ----

function Read-Json([string]$Path, $Default) {
  if (-not (Test-Path -LiteralPath $Path)) { return $Default }
  try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
  catch { Say "could not read $Path; starting that record over"; return $Default }
}

function Write-Json([string]$Path, $Object) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  ConvertTo-Json -InputObject $Object -Depth 6 | Set-Content -LiteralPath "$Path.tmp" -Encoding UTF8
  Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}

function Read-Ledger([string]$Path) {
  $files = @{}; $mods = @{}
  $raw = Read-Json $Path $null
  if ($raw) {
    foreach ($p in @((Get-Prop $raw 'files' $null).PSObject.Properties)) {
      if ($p) { $files[[string]$p.Name] = @{ sha256 = [string]$p.Value.sha256; server = [string]$p.Value.server; mod = [string]$p.Value.mod } }
    }
    foreach ($p in @((Get-Prop $raw 'mods' $null).PSObject.Properties)) {
      if ($p) { $mods[[string]$p.Name] = @{ version = [string]$p.Value.version; archive = [string]$p.Value.archive; identity = [string](Get-Prop $p.Value 'identity' ''); files = @(Get-Prop $p.Value 'files' @()) } }
    }
  }
  return @{ files = $files; mods = $mods }
}

function Write-Ledger([string]$Path, $Ledger) {
  $files = [ordered]@{}; $mods = [ordered]@{}
  foreach ($k in ($Ledger.files.Keys | Sort-Object)) { $files[$k] = $Ledger.files[$k] }
  foreach ($k in ($Ledger.mods.Keys | Sort-Object)) {
    # Plain objects: Windows PowerShell's ConvertTo-Json fails on a list nested in a hashtable.
    $proof = @(foreach ($e in @($Ledger.mods[$k].files)) { [pscustomobject]@{ path = [string]$e.path; sha256 = [string]$e.sha256 } })
    $mods[$k] = [pscustomobject]@{ version = [string]$Ledger.mods[$k].version; archive = [string]$Ledger.mods[$k].archive; identity = [string]$Ledger.mods[$k].identity; files = $proof }
  }
  Write-Json $Path ([ordered]@{ files = $files; mods = $mods })
}

# What makes Moonpool's mods load: its own loader proxy, its mods' enabled.txt and their pak trios.
# Off is a rename beside the file, and only a file that still matches what this launcher placed is
# switched, so a player's own loader and mods are never touched. Returns what stayed in use.
function Test-Switchable([string]$Path) { (@('dwmapi.dll', 'enabled.txt') -contains (Split-Path -Leaf $Path)) -or ($TrioExtensions -contains [IO.Path]::GetExtension($Path)) }

function Switch-MoonpoolMods([bool]$On) {
  $ledger = Read-Ledger (Join-Path $KitHome 'owned.json')
  $left = @(); $stuck = @()
  foreach ($path in @($ledger.files.Keys)) {
    if (-not (Test-Switchable $path)) { continue }
    $sha = $ledger.files[$path].sha256
    $from = $path; if ($On) { $from = "$path.moonpool-off" }
    if (-not (Test-Path -LiteralPath $from) -or (Get-Sha256 $from) -ne $sha) { continue }
    $from = (Get-Item -LiteralPath $from).FullName
    $to = "$from.moonpool-off"; if ($On) { $to = $from.Substring(0, $from.Length - '.moonpool-off'.Length) }
    if ((Test-Path -LiteralPath $to) -and (Get-Sha256 $to) -ne $sha) { if (-not $On) { $stuck += $from }; continue }
    $left += [pscustomobject]@{ From = $from; To = $to }
  }
  # A game that just closed, Defender or a crash reporter can hold a file for a few seconds.
  for ($try = 0; $left.Count -gt 0 -and $try -lt 10; $try++) {
    if ($try) { Start-Sleep -Seconds 2 }
    $left = @($left | Where-Object {
      try { if (Test-Path -LiteralPath $_.To) { Remove-Item -LiteralPath $_.To -Force }; Move-Item -LiteralPath $_.From -Destination $_.To; $false }
      catch { $true } })
  }
  # Moonpool's loader runs with the files the server sent. A UE4SS_Signatures folder it was not sent replaces
  # the loader's own search for the game's tables, and an outdated one stops every script mod from starting.
  # It is set aside while Moonpool's mods are on and put back when they go off; nothing in it is changed.
  foreach ($key in @($ledger.files.Keys | Where-Object { (Split-Path -Leaf $_) -ieq 'dwmapi.dll' })) {
    $sig = Join-Path (Join-Path (Split-Path -Parent $key) 'ue4ss') 'UE4SS_Signatures'
    if (@($ledger.files.Keys | Where-Object { $_.StartsWith("$sig\", [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
    $aside = "$sig.moonpool-off"
    try {
      if ($On -and (Test-Path -LiteralPath $sig) -and -not (Test-Path -LiteralPath $aside)) {
        Move-Item -LiteralPath $sig -Destination $aside
        Say "set aside ue4ss\UE4SS_Signatures, which this server's loader does not use and which can stop its script mods; it is put back when the game closes"
      } elseif (-not $On -and (Test-Path -LiteralPath $aside) -and -not (Test-Path -LiteralPath $sig)) {
        Move-Item -LiteralPath $aside -Destination $sig
      }
    } catch { Say "could not move ue4ss\UE4SS_Signatures ($($_.Exception.Message)); script mods may not start" }
  }
  return @($stuck) + @($left | ForEach-Object { $_.From })
}

# One launcher at a time for this Windows user in any session, from turning the mods on until they are off again.
function Enter-Lock {
  $name = 'Global\moonpool-launcher-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $lock = New-Object Threading.Mutex($false, $name)
  try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
  if (-not $held) {
    # A second click on the link while the first launcher's window is up: that window comes forward and no second one opens.
    $first = Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq 'Moonpool' } | Select-Object -First 1
    if ($first) {
      $script:FirstWindowShown = $true
      try { [void](New-Object -ComObject WScript.Shell).AppActivate($first.Id) } catch { }
    }
    Fail 'another Moonpool launcher is running, and it stays until Subnautica 2 closes; nothing changed' 2
  }
  $script:Lock = $lock
}

# ---- the manifest ------------------------------------------------------------------

function Get-Manifest($Config) {
  $work = Join-Path ([IO.Path]::GetTempPath()) ('moonpool-manifest-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $manifestFile = Join-Path $work 'mods.json'
    Save-Url $ManifestUrl $manifestFile
    if ($Config) {
      $sigUrl = $ManifestUrl + '.sig'
      $sigFile = Join-Path $work 'mods.json.sig'
      Save-Url $sigUrl $sigFile
      if (-not (Test-ManifestSignature $manifestFile $sigFile $Config.public_key)) {
        Fail 'the server mod list signature is invalid; nothing changed, game not started'
      }
    } elseif (-not $ManifestUrl.StartsWith('file:')) {
      Fail 'this mod list came with no server key; open the server from its join page'
    }
    return (Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json)
  } catch { Fail "could not verify the server's mod list at ${ManifestUrl}: $($_.Exception.Message)" }
  finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# Updates come from the project's own release, never from a game server, and must carry the
# release key's signature and a higher build. Anything else keeps the installed copy.
function Update-Launcher {
  if (-not (Test-Path -LiteralPath $InstalledScript) -or [IO.Path]::GetFullPath($PSCommandPath) -ine [IO.Path]::GetFullPath($InstalledScript)) { return $false }
  $url = $env:SN2_JOIN_UPDATE_URL
  if (-not $url) { $url = "$ReleaseBase/moonpool.ps1" }
  $file = Join-Path ([IO.Path]::GetTempPath()) ('moonpool-update-' + [guid]::NewGuid().ToString('N') + '.ps1')
  try {
    Save-Url $url $file
    Save-Url "$url.sig" "$file.sig"
    if (-not (Test-ManifestSignature $file "$file.sig" $ReleaseKey)) { return $false }
    if ((Get-Content -LiteralPath $file -Raw) -notmatch '(?m)^\$LauncherBuild = (\d+)' -or [int]$Matches[1] -le $LauncherBuild) { return $false }
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) { return $false }
    Copy-Item -LiteralPath $file -Destination $InstalledScript -Force
  } catch { return $false } finally { Remove-Item -LiteralPath $file, "$file.sig" -Force -ErrorAction SilentlyContinue }
  Say 'updated the launcher; restarting'
  if ($Launch) { & $Launch 'self-update' }
  else {
    $run = Get-HiddenRun
    $again = "$($run.Prefix)-NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`""
    if ($Link) { $again += " -Link `"$Link`"" } elseif ($Server) { $again += " -Server `"$Server`"" }
    Close-Window
    Start-Process $run.Exe -ArgumentList $again
  }
  return $true
}

function Test-GameBuild($Manifest, [string]$Acf) {
  $serverGame = Get-Prop $Manifest 'game' $null
  $wantBuild = [string](Get-Prop $serverGame 'buildid' '')
  $wantBranch = [string](Get-Prop $serverGame 'branch' 'public')
  if (-not $wantBranch) { $wantBranch = 'public' }
  $haveBuild = ''; $haveBranch = ''
  if ($Acf) { $haveBuild = Get-AcfValue $Acf 'buildid'; $haveBranch = Get-AcfValue $Acf 'BetaKey' }
  if (-not $haveBranch) { $haveBranch = 'public' }
  if ($wantBuild -and ($haveBuild -ne $wantBuild -or $haveBranch -ne $wantBranch)) {
    Fail "server needs Steam branch '$wantBranch' build $wantBuild; pick that branch in Subnautica 2 > Properties > Betas and let Steam update"
  }
}

# ---- choosing what this server wants locally -------------------------------------------

function Get-Choices([string]$Path, $Manifest) {
  $raw = Read-Json $Path $null
  $skipped = New-Object System.Collections.Generic.List[string]
  if ($null -eq $raw) {
    # Nothing chosen yet for this server: an optional mod the host marked default_on false starts left out.
    foreach ($m in @(Get-Prop $Manifest 'mods' @())) {
      if (-not [bool](Get-Prop $m 'required' $true) -and -not [bool](Get-Prop $m 'default_on' $true)) { $skipped.Add([string](Get-Prop $m 'name' '')) }
    }
  }
  foreach ($n in @(Get-Prop $raw 'skipped' @())) { if ($n) { $skipped.Add([string]$n) } }
  foreach ($n in $Keep) { while ($skipped.Contains($n)) { [void]$skipped.Remove($n) } }
  foreach ($n in $Skip) { if (-not $skipped.Contains($n)) { $skipped.Add($n) } }
  if ($Skip.Count -gt 0 -or $Keep.Count -gt 0) { Write-Json $Path ([ordered]@{ skipped = @($skipped); seen = @(Get-Prop $raw 'seen' @()) }) }
  return ,$skipped
}

# Validates the manifest's mods and returns the ones to install.
function Get-WantedMods($Manifest, $Skipped) {
  $wanted = New-Object System.Collections.Generic.List[object]
  $folders = @{}
  foreach ($mod in @(Get-Prop $Manifest 'mods' @())) {
    $name = [string](Get-Prop $mod 'name' '')
    if (-not $name) { Fail 'the server manifest has a mod without a name' }
    $kind = [string](Get-Prop $mod 'kind' 'ue4ss')
    if ($kind -notin @('ue4ss', 'pak')) { Fail "mod $name has an unknown kind '$kind'; this launcher needs an update" }
    $folder = [string](Get-Prop $mod 'folder' '')
    if ($folder -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { Fail "mod $name has an unsafe install folder '$folder'" }
    if ($folders.ContainsKey($folder.ToLowerInvariant())) { Fail "mods $($folders[$folder.ToLowerInvariant()]) and $name install the same folder $folder" }
    $folders[$folder.ToLowerInvariant()] = $name
    $source = Get-Prop $mod 'source' $null
    if (-not $source) { Fail "mod $name has no source" }
    $fileName = [string](Get-Prop $source 'file_name' '')
    if ($fileName -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.+()\[\]-]*\.zip$') { Fail "mod $name has an unsafe archive name '$fileName'" }
    # The prefix picks the folder inside the unpacked archive; every part stays a plain name in it.
    $prefix = ([string](Get-Prop $mod 'prefix' '')).Trim('/')
    if ($prefix -and @($prefix -split '/' | Where-Object { $_ -notmatch '^[A-Za-z0-9_][A-Za-z0-9 _.+()\[\]-]*$' }).Count) {
      Fail "mod $name has an unsafe folder inside its archive '$prefix'"
    }
    if (@(Get-Prop $source 'hashes' @()).Count -eq 0) { Fail "mod $name has no archive hash" }
    $required = [bool](Get-Prop $mod 'required' $true)
    if (-not $required -and $Skipped.Contains($name)) {
      Say "leaving out optional mod $name (you chose to; run with -Keep '$name' to take it back)"
      continue
    }
    $wanted.Add([pscustomobject]@{
      Identity = "$kind|$folder|$prefix"
      Name = $name; Version = [string](Get-Prop $mod 'version' ''); Required = $required; Kind = $kind
      Folder = $folder; Prefix = $prefix; Source = $source
      Native = [bool](Get-Prop $mod 'native' $false)
      # The archive's name in the ledger: its sha256 when the server listed one, else the first hash.
      ArchiveSha = (([string](Get-Prop (@(@(Get-Prop $source 'hashes' @()) | Where-Object { ([string](Get-Prop $_ 'algorithm' '')).ToLowerInvariant() -eq 'sha256' }) + @(Get-Prop $source 'hashes' @()) | Select-Object -First 1) 'value' '')).ToLowerInvariant())
    })
  }
  return ,$wanted
}

# Where a mod's files live locally: a UE4SS mod is a folder under ue4ss\Mods,
# a pak mod is its trio in Content\Paks\~mods.
function Get-ModTargets($Mod, [string]$Game) {
  $win64 = Join-Path $Game 'Subnautica2\Binaries\Win64'
  if ($Mod.Kind -eq 'ue4ss') { return (Join-Path $win64 ("ue4ss\Mods\" + $Mod.Folder)) }
  return (Join-Path $Game 'Subnautica2\Content\Paks\~mods')
}

# Finds the archive for a mod: a direct download, or a file the player saved in
# Downloads for a site that needs their own sign-in. Verified before it is used.
function Get-ModArchive($Mod, [string]$Stage) {
  $source = $Mod.Source
  $url = [string](Get-Prop $source 'url' '')
  $fileName = [string](Get-Prop $source 'file_name' '')
  $dest = Join-Path $Stage $fileName
  if ($url) {
    try { Save-Url (Resolve-Url $ManifestUrl $url) $dest }
    catch { Fail "could not download $fileName for $($Mod.Name): $($_.Exception.Message); nothing changed, game not started" }
  } else {
    $page = [string](Get-Prop $source 'page' '')
    $candidate = Join-Path (Get-DownloadsFolder) $fileName
    if (-not (Test-Path -LiteralPath $candidate)) {
      Say "$($Mod.Name) comes from a site that needs your own sign-in; opening its page"
      if ($page -notmatch '^https://[^\s"]+$') { Fail "$($Mod.Name) names a page that is not an https address; nothing changed, game not started" }
      if ($OpenPage) { & $OpenPage $page } else { Start-Process $page }
      Fail "download $fileName from $page (the plain download is enough), leave it in Downloads, then start again; nothing changed, game not started"
    }
    Copy-Item -LiteralPath $candidate -Destination $dest
  }
  $problem = Test-Hashes $dest (Get-Prop $source 'hashes' @())
  if ($problem) { Fail "$($Mod.Name): $fileName $problem; nothing changed, game not started" }
  return $dest
}

# Windows Defender's verdict on a file: clean, threat, or unscanned when Defender is missing or
# its scan failed. MpCmdRun exits 2 for a threat and for a failed scan, so the result it prints
# decides. The test hook may answer $true/$false (clean/threat) or one of the three words.
function Get-DefenderVerdict([string]$Path) {
  if ($ScanFile) {
    $v = & $ScanFile $Path
    if ($v -is [bool]) { if ($v) { return 'clean' } else { return 'threat' } }
    return [string]$v
  }
  $tool = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
  if (-not (Test-Path -LiteralPath $tool)) { Say 'Windows Defender not found, so this file was not scanned'; return 'unscanned' }
  $result = & $tool -Scan -ScanType 3 -File $Path -DisableRemediation 2>&1 | Out-String
  if ($result -match 'found [1-9][0-9]* threats') { return 'threat' }
  if ($LASTEXITCODE -ne 0) { Say "Windows Defender could not scan this file (exit $LASTEXITCODE), so it was not scanned"; return 'unscanned' }
  return 'clean'
}

# An unscanned archive installs only on a yes, remembered per archive so it is asked once.
function Confirm-Unscanned([string]$Archive, [string]$Label, [string]$ServerId) {
  $sha = Get-Sha256 $Archive
  $path = Join-Path $KitHome "$ServerId\unscanned.json"
  $okayed = @(Read-Json $path @())
  if ($okayed -contains $sha) { return }
  $text = "${Label} could not be scanned by Windows Defender (not installed, or the scan failed).`n`nNothing says it is safe. Install it anyway?"
  if ($Approve) { $yes = & $Approve $text } else { $yes = Show-Question $text 'Windows Defender could not scan this' 'Install anyway' 'Cancel' }
  if (-not $yes) { Fail "${Label}: not scanned and you declined; nothing changed, game not started" 3 }
  Write-Json $path @($okayed + $sha)
}

# A signed hash proves the player got the archive the server inspected, not that the
# archive is safe: every entry is checked before anything is unpacked.
function Assert-ArchiveSafe([string]$Archive, [string]$Label) {
  Say "Checking $Label with Windows Defender"
  $verdict = Get-DefenderVerdict $Archive
  if ($verdict -eq 'threat') { Fail "${Label}: Windows Defender flagged this file; nothing changed, game not started" }
  if ($verdict -ne 'clean') { Confirm-Unscanned $Archive $Label $script:ServerId }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    if ($zip.Entries.Count -gt $MaxArchiveEntries) { Fail "${Label}: the archive holds $($zip.Entries.Count) files, more than this launcher accepts; nothing changed, game not started" }
    $total = [long]0
    $seen = @{}
    foreach ($entry in $zip.Entries) {
      $name = ($entry.FullName -replace '\\', '/')
      if ($name.StartsWith('/')) { Fail "${Label}: unsafe path in the archive: $name; nothing changed, game not started" }
      foreach ($part in $name.TrimEnd('/').Split('/')) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..' -or $part.Contains(':') -or $part -match '[. ]$' -or $part -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)') {
          Fail "${Label}: unsafe path in the archive: $name; nothing changed, game not started"
        }
      }
      if ($seen.ContainsKey($name.ToLowerInvariant())) { Fail "${Label}: the archive names $name twice; nothing changed, game not started" }
      $seen[$name.ToLowerInvariant()] = $true
      $total += $entry.Length
      if ($total -gt $MaxUnpackedBytes) { Fail "${Label}: the archive unpacks to more than this launcher accepts; nothing changed, game not started" }
    }
  } finally { $zip.Dispose() }
}

# Unpacks a checked archive, counting the bytes really written: a size an archive declares can lie.
function Expand-Counted([string]$Archive, [string]$Dest, [string]$Label) {
  $root = [IO.Path]::GetFullPath($Dest).TrimEnd('\') + '\'
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  $buf = New-Object byte[] 65536
  $total = [long]0
  try {
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName -replace '\\', '/'
      $path = [IO.Path]::GetFullPath($root + ($name -replace '/', '\'))
      if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Fail "${Label}: unsafe path in the archive: $name; nothing changed, game not started" }
      if ($name.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($path); continue }
      [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
      $in = $null; $out = $null
      try {
        $in = $entry.Open()
        # CreateNew: two names that land on one file (a short 8.3 name, say) never overwrite each other.
        try { $out = [IO.File]::Open($path, [IO.FileMode]::CreateNew) }
        catch { if (-not (Test-Path -LiteralPath $path)) { throw }; Fail "${Label}: two entries in the archive land on the same file ($name); nothing changed, game not started" }
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
          $total += $n
          if ($total -gt $MaxUnpackedBytes) { Fail "${Label}: the archive unpacks to more than this launcher accepts; nothing changed, game not started" }
          $out.Write($buf, 0, $n)
        }
      } finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
      }
      [IO.File]::SetLastWriteTime($path, $entry.LastWriteTime.DateTime)
    }
  } finally { $zip.Dispose() }
}

# Unpacks the part of an archive this mod is (its prefix) into stage\<folder>\ and
# returns the files as relative paths with their hashes.
function Expand-ModArchive($Mod, [string]$Archive, [string]$Stage) {
  $unpacked = Join-Path $Stage ('unpacked-' + $Mod.Folder)
  Assert-ArchiveSafe $Archive $Mod.Name
  Expand-Counted $Archive $unpacked $Mod.Name
  $root = $unpacked
  if ($Mod.Prefix) {
    if ($Mod.Kind -eq 'ue4ss') { $root = Join-Path $unpacked ($Mod.Prefix -replace '/', '\') }
  }
  $files = New-Object System.Collections.Generic.List[object]
  if ($Mod.Kind -eq 'ue4ss') {
    if (-not (Test-Path -LiteralPath $root)) { Fail "$($Mod.Name): the archive has no folder '$($Mod.Prefix)'; the server's list is stale" }
    foreach ($f in Get-ChildItem -LiteralPath $root -File -Recurse) {
      $rel = $f.FullName.Substring($root.Length).TrimStart('\')
      $files.Add([pscustomobject]@{ Rel = $rel; Path = $f.FullName; Sha256 = (Get-Sha256 $f.FullName) })
    }
    if (-not ($files | Where-Object { $_.Rel -ieq 'Scripts\main.lua' -or $_.Rel -ieq 'dlls\main.dll' })) {
      Fail "$($Mod.Name): the archive holds no UE4SS mod at '$($Mod.Prefix)'"
    }
    # Many mods ship their own enabled.txt; a second one would fight it for the same path.
    if (-not ($files | Where-Object { $_.Rel -ieq 'enabled.txt' })) {
      $marker = Join-Path $Stage ("enabled-" + $Mod.Folder + ".txt")
      New-Item -ItemType File -Path $marker -Force | Out-Null
      $files.Add([pscustomobject]@{ Rel = 'enabled.txt'; Path = $marker; Sha256 = (Get-Sha256 $marker) })
    }
  } elseif ($Mod.Prefix -and (Test-Path -LiteralPath (Join-Path $unpacked ($Mod.Prefix -replace '/', '\')) -PathType Container)) {
    # A folder of trios: the author's set, each file placed in ~mods under its own name.
    $dir = Join-Path $unpacked ($Mod.Prefix -replace '/', '\')
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $TrioExtensions -contains $_.Extension.ToLowerInvariant() })) {
      $files.Add([pscustomobject]@{ Rel = $f.Name; Path = $f.FullName; Sha256 = (Get-Sha256 $f.FullName) })
    }
    if ($files.Count -eq 0) { Fail "$($Mod.Name): the archive has no .pak files in '$($Mod.Prefix)'; the server's list is stale" }
  } else {
    $stem = ($Mod.Prefix -replace '/', '\')
    foreach ($ext in $TrioExtensions) {
      $p = Join-Path $unpacked ($stem + $ext)
      if (-not (Test-Path -LiteralPath $p)) { Fail "$($Mod.Name): $($Mod.Folder)$ext is missing from the archive" }
      $files.Add([pscustomobject]@{ Rel = ($Mod.Folder + $ext); Path = $p; Sha256 = (Get-Sha256 $p) })
    }
  }
  return $files
}

# The loader itself, when the manifest says any mod needs it: the server's own pinned build.
function Get-LoaderFiles($Spec, [string]$Stage) {
  $zip = Join-Path $Stage 'ue4ss.zip'
  try { Save-Url (Resolve-Url $ManifestUrl ([string]$Spec.url)) $zip }
  catch { Fail "could not download the UE4SS loader: $($_.Exception.Message); nothing changed, game not started" }
  if ((Get-Sha256 $zip) -ne ([string]$Spec.sha256).ToLowerInvariant()) { Fail 'the UE4SS loader failed its sha256 check; nothing changed, game not started' }
  $loader = Join-Path $Stage 'unpacked-ue4ss'
  Assert-ArchiveSafe $zip 'the UE4SS loader'
  Expand-Counted $zip $loader 'the UE4SS loader'
  $src = $loader
  if (Test-Path -LiteralPath (Join-Path $loader 'ue4ss\UE4SS.dll')) { $src = Join-Path $loader 'ue4ss' }
  if (-not (Test-Path -LiteralPath (Join-Path $src 'UE4SS.dll'))) { Fail 'the UE4SS loader archive has no UE4SS.dll' }
  $proxy = Get-ChildItem -LiteralPath $loader -Filter dwmapi.dll -File -Recurse | Select-Object -First 1
  if (-not $proxy) { Fail 'the UE4SS loader archive has no dwmapi.dll' }
  $files = New-Object System.Collections.Generic.List[object]
  $files.Add([pscustomobject]@{ Rel = 'dwmapi.dll'; Path = $proxy.FullName; Sha256 = (Get-Sha256 $proxy.FullName) })
  foreach ($f in Get-ChildItem -LiteralPath $src -File -Recurse) {
    $rel = $f.FullName.Substring($src.Length).TrimStart('\')
    if ($rel -ieq 'dwmapi.dll') { continue }
    $files.Add([pscustomobject]@{ Rel = ('ue4ss\' + $rel); Path = $f.FullName; Sha256 = (Get-Sha256 $f.FullName) })
  }
  return $files
}

# ---- placing files ----------------------------------------------------------------------

# Every planned file goes in and every removal goes out together; on a failure
# everything is put back as it was.
function Install-Plan($Plan, $Removals, [string]$Stage, [string]$Outcome = 'could not place the mod files ({0}); the previous set was put back, game not started') {
  $prev = Join-Path $Stage 'previous'
  New-Item -ItemType Directory -Path $prev -Force | Out-Null
  $placed = New-Object System.Collections.Generic.List[object]
  try {
    $i = 0
    foreach ($f in $Plan) {
      $target = $f.Target
      $dir = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      $backup = $null
      if (Test-Path -LiteralPath $target) {
        $backup = Join-Path $prev ("$i-" + (Split-Path -Leaf $target))
        Move-Item -LiteralPath $target -Destination $backup
      }
      $placed.Add([pscustomobject]@{ Target = $target; Backup = $backup })
      Move-Item -LiteralPath $f.Path -Destination $target
      $i++
    }
    foreach ($path in $Removals) {
      $backup = Join-Path $prev ("$i-" + (Split-Path -Leaf $path))
      Move-Item -LiteralPath $path -Destination $backup
      $placed.Add([pscustomobject]@{ Target = $path; Backup = $backup })
      $i++
    }
  } catch {
    $why = $_.Exception.Message
    for ($k = $placed.Count - 1; $k -ge 0; $k--) {
      $p = $placed[$k]
      if (Test-Path -LiteralPath $p.Target) { Remove-Item -LiteralPath $p.Target -Force }
      if ($p.Backup -and (Test-Path -LiteralPath $p.Backup)) { Move-Item -LiteralPath $p.Backup -Destination $p.Target }
    }
    Fail ($Outcome -f $why)
  }
}

function Set-ModRecord($Ledger, [string]$ServerId, $Mod, $Expected) {
  $Ledger.mods["$ServerId/$($Mod.Name)"] = @{ version = [string]$Mod.Version; archive = [string]$Mod.ArchiveSha; identity = [string]$Mod.Identity; files = @($Expected[[string]$Mod.Name]) }
}

function Remove-EmptyDirs([string]$Path, [string]$Stop) {
  $d = $Path
  while ($d -and $d.Length -gt $Stop.Length -and $d.StartsWith($Stop, [StringComparison]::OrdinalIgnoreCase)) {
    if (-not (Test-Path -LiteralPath $d)) { $d = Split-Path -Parent $d; continue }
    if (@(Get-ChildItem -LiteralPath $d -Force).Count -gt 0) { return $d }
    Remove-Item -LiteralPath $d -Force
    $d = Split-Path -Parent $d
  }
}

# Ledger files not in $Keep go only while their bytes are the ones placed, live or (with $Parked)
# switched off. Anything else may be the player's now: it stays and is named.
function Get-Removals($Ledger, $Keep, [bool]$Parked) {
  $remove = New-Object System.Collections.Generic.List[string]; $kept = New-Object System.Collections.Generic.List[string]
  foreach ($path in @($Ledger.files.Keys)) {
    if ($Keep.ContainsKey($path)) { continue }
    $copies = @($path); if ($Parked -and (Test-Switchable $path)) { $copies += "$path.moonpool-off" }
    foreach ($p in $copies) {
      if (-not (Test-Path -LiteralPath $p)) { continue }
      if ((Get-Sha256 $p) -eq $Ledger.files[$path].sha256) { $remove.Add($p) } else { $kept.Add($p) }
    }
  }
  return @{ Remove = $remove; Kept = $kept }
}

# The folders removals left empty, up to the game's own Win64 or Paks folder. Returns the loader's
# or a mod's own folder when it stayed because the mod wrote files there while it ran.
function Remove-EmptyParents($Paths) {
  $full = @{}
  foreach ($path in $Paths) {
    if ($path -notmatch '^(.+?\\subnautica2\\(binaries\\win64|content\\paks))\\') { continue }
    $left = Remove-EmptyDirs (Split-Path -Parent $path) $Matches[1]
    if (-not $left) { continue }
    $rel = $left.Substring($Matches[1].Length + 1)
    if ($rel -match '^ue4ss(\\|$)' -and $rel -ne 'ue4ss\Mods') { $full[$left] = $true }
  }
  return @($full.Keys)
}

function Invoke-Uninstall {
  Enter-Lock
  if (Test-GameRunning) { Fail 'Subnautica 2 is running; close it and start this again (nothing was changed)' 2 }
  $gone = Get-Removals (Read-Ledger (Join-Path $KitHome 'owned.json')) @{} $true
  if ($gone.Remove.Count -gt 0) {
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('moonpool-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Work | Out-Null
    Install-Plan @() $gone.Remove $script:Work "could not remove Moonpool's files ({0}); nothing was removed, close Subnautica 2 and try again"
    # The loader's folder counts without Mods beneath it, which may hold the player's own mods.
    $stayed = @(Remove-EmptyParents $gone.Remove | Where-Object { $dir = $_; $mods = "$dir\Mods\"
      @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $gone.Kept -notcontains $_.FullName.ToLowerInvariant() -and
        -not ($dir -match '\\ue4ss$' -and $_.FullName.StartsWith($mods, [StringComparison]::OrdinalIgnoreCase)) }).Count -gt 0 })
  } else { $stayed = @() }
  $done = @("$($gone.Remove.Count) game file(s) it placed")
  # The handler goes only while it still opens this launcher; another program may have taken the name.
  $key = Get-HandlerKey
  $command = [string](Get-Prop (Get-ItemProperty -LiteralPath "$key\shell\open\command" -ErrorAction SilentlyContinue) '(default)' '')
  if ($command.IndexOf("-File `"$InstalledScript`"", [StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-Item -LiteralPath $key -Recurse -Force; $done += 'its moonpool: link handler' }
  $links = 0
  $shell = New-Object -ComObject WScript.Shell
  foreach ($dir in Get-ShortcutFolders) {
    foreach ($lnk in @(Get-ChildItem -LiteralPath $dir -Filter 'Subnautica 2 (*).lnk' -File -ErrorAction SilentlyContinue)) {
      if ($shell.CreateShortcut($lnk.FullName).Arguments.IndexOf("-File `"$InstalledScript`"", [StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-Item -LiteralPath $lnk.FullName -Force; $links++ }
    }
  }
  # A shortcut's console keeps this folder as its working folder until this run ends.
  $temp = [IO.Path]::GetTempPath()
  [IO.Directory]::SetCurrentDirectory($temp); Set-Location -LiteralPath $temp
  $done += "$links shortcut(s)"
  $folder = $null
  if (Test-Path -LiteralPath $KitHome) {
    $folder = "its folder $KitHome"
    try { Remove-Item -LiteralPath $KitHome -Recurse -Force } catch { }
  }
  if ($folder -and (Test-Path -LiteralPath $KitHome)) {
    if (@(Get-ChildItem -LiteralPath $KitHome -Force).Count -gt 0) { $folder = "not all of $KitHome (a file there is in use; delete the folder yourself)" }
    else {
      # Once this run and the console it ran in have closed; a non-recursive delete only takes an empty folder.
      $q = $KitHome -replace "'", "''"
      $wait = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; for (`$i = 0; `$i -lt 60 -and (Test-Path -LiteralPath '$q'); `$i++) { try { [IO.Directory]::Delete('$q') } catch { Start-Sleep -Milliseconds 500 } }"
      Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -WorkingDirectory $temp -ArgumentList "-NoProfile -EncodedCommand $([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wait)))"
      $folder = "its folder $KitHome (emptied now, gone once this closes)"
    }
  }
  if ($folder) { $done += $folder }
  $text = "Moonpool is uninstalled. Removed " + ($done -join ', ') + '.'
  if ($gone.Kept.Count -gt 0) { $text += "`n`nLeft in place because they changed after Moonpool placed them, so they may be yours: " + ($gone.Kept -join ', ') }
  if ($stayed.Count -gt 0) { $text += "`n`nStill there, holding files Moonpool never placed, such as a mod's own settings or log: " + ($stayed -join ', ') }
  $text += "`n`nFiles of yours that Moonpool replaced after asking are not put back; their copies stay in $(Join-Path $env:LOCALAPPDATA 'Moonpool-replaced'). With -Adopt no copy was kept. Steam's Verify integrity of game files restores any of the game's own files."
  Write-Host "moonpool: $text"
  if (-not $env:SN2_JOIN_NO_DIALOG) { Show-Notice 'Moonpool is uninstalled' $text }
}

function Invoke-Join {
  if ($Link) {
    if ($BoundCount -ne 1) { Fail 'a join link comes alone; this one carried other options and was refused' }
    if ($Link -notmatch '^moonpool:(.+)$' -or -not (Test-ServerAddress $Matches[1])) { Fail "not a server address this launcher accepts (https, or http on a private network): $Link" }
    $script:Server = ($Link -replace '^moonpool:', '')
  }
  if ($Uninstall) { Invoke-Uninstall; return }
  if ($DisableMoonpoolMods) {
    Enter-Lock
    $left = @(Switch-MoonpoolMods $false)
    if ($left.Count -gt 0) { Fail ("could not turn Moonpool's mods off, still in use: " + ($left -join ', ') + '; close Subnautica 2 and try again') }
    Say "Moonpool's mods are off; starting Subnautica 2 without them"
    $url = "steam://rungameid/$DefaultAppId"
    if ($Launch) { & $Launch $url } else { Start-Process $url }
    return
  }
  if ($Install -or (-not $Server -and -not $ManifestUrl)) {
    Install-Launcher
    Say "installed. Go back to the server's join page and press Play with mods."
    return
  }
  Open-Window
  if (Update-Launcher) { return }
  Enter-Lock
  if (Test-GameRunning) { Fail 'Subnautica 2 is running; close it and start this again (nothing was changed)' 2 }
  # On here, so the ledger finds every file where it was placed, and off again when this run ends,
  # which also clears what a launcher that died left on.
  $script:ModsOn = $true
  $left = @(Switch-MoonpoolMods $true)
  if ($left.Count -gt 0) { Fail ("could not turn Moonpool's mods on, in use: " + ($left -join ', ') + '; nothing was started') }
  $cfg = $null; $serverId = ''
  if ($Server -match '^[0-9a-f]{16}$') {
    $cfg = Read-Json (Join-Path $KitHome "$Server\moonpool.json") $null
    if (-not $cfg) { Fail 'this shortcut is for a server not set up on this PC; open it from its join page' }
  } elseif ($Server) {
    if (-not $Server.StartsWith('file:') -and -not (Test-ServerAddress $Server)) { Fail "not a server address this launcher accepts (https, or http on a private network): $Server" }
    Install-Launcher
    $cfg = Read-ServerConfig $Server
  }
  if ($cfg) {
    if ($cfg.address -like 'file:*') { $script:AllowLocal = $true }
    $serverId = Get-ServerId $cfg
    $script:ServerId = $serverId
    Set-UiServer ([string](Get-Prop $cfg 'server_name' ''))
    $script:ManifestUrl = "$($cfg.address)/mods.json"
  }

  $manifest = Get-Manifest $cfg
  if ([int](Get-Prop $manifest 'schema' 0) -ne 3) { Fail 'the server mod list has an unknown schema; this launcher needs an update' }
  $appId = [string](Get-Prop $manifest 'app_id' $DefaultAppId)
  if ($appId -notmatch '^[0-9]+$') { Fail "the server mod list names an invalid app id '$appId'" }
  $root = $SteamRoot
  if (-not $root) { $root = Get-DefaultSteamRoot }
  Test-GameBuild $manifest (Find-AppManifest $root $appId)
  $game = Find-GameFolder $root $appId
  Write-Host "moonpool: game found at $game"
  Set-Status 'Found the game'
  if (-not $serverId) { $serverId = 'test-' + ([string](Get-Prop (Get-Prop $manifest 'server' $null) 'id' 'none') -replace '[^A-Za-z0-9-]', '_') }
  $ledgerPath = Join-Path $KitHome 'owned.json'
  $ledger = Read-Ledger $ledgerPath
  $choicesPath = Join-Path $KitHome "$serverId\choices.json"
  $skipped = Get-Choices $choicesPath $manifest
  $wanted = Get-WantedMods $manifest $skipped
  $chosen = $false
  if ($script:Ui -and -not $Approve -and $cfg) {
    $all = Get-WantedMods $manifest (New-Object System.Collections.Generic.List[string])
    $firstLoader = $null; if ($wanted | Where-Object { $_.Kind -eq 'ue4ss' }) { $firstLoader = Get-Prop $manifest 'ue4ss' $null }
    $accepted = @(Read-Json (Join-Path $KitHome "$serverId\accepted.json") @())
    $unanswered = @((Get-CodeSet $wanted $firstLoader) | Where-Object { $accepted -notcontains $_ })
    $optionalNames = @($all | Where-Object { -not $_.Required } | ForEach-Object { $_.Name })
    $seen = @(Get-Prop (Read-Json $choicesPath $null) 'seen' @())
    $unseen = @($optionalNames | Where-Object { $seen -notcontains $_ })
    if (($unanswered.Count -gt 0 -or $unseen.Count -gt 0) -and $optionalNames.Count -gt 0) {
      $skipped = Show-ModPicker $all $skipped $cfg $serverId (Get-Prop $manifest 'ue4ss' $null)
      Write-Json $choicesPath ([ordered]@{ skipped = @($skipped); seen = @($optionalNames) })
      $wanted = Get-WantedMods $manifest $skipped
      $chosen = $true
    }
  }
  $loaderSpec = $null
  if ($wanted | Where-Object { $_.Kind -eq 'ue4ss' }) {
    $loaderSpec = Get-Prop $manifest 'ue4ss' $null
    if (-not $loaderSpec) { Fail 'the server lists UE4SS mods but no loader; the server-side list is incomplete' }
    # Every session, because a Steam update changes the game under a loader already in place.
    $exe = Get-ChildItem -LiteralPath (Join-Path $game 'Subnautica2\Binaries\Win64') -Filter 'Subnautica2-Win64-*.exe' -File | Select-Object -First 1
    $digest = ''
    if ($exe) { $digest = Get-Sha256 $exe.FullName }
    if (-not $digest -or @((Get-Prop $loaderSpec 'allowed_builds' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() }) -notcontains $digest) {
      Fail "the server's mods need the UE4SS loader, which the server has not listed for this game build ($($digest.Substring(0, [Math]::Min(12, $digest.Length)))); ask the admin to allow it, nothing changed, game not started"
    }
  }
  $win64 = Join-Path $game 'Subnautica2\Binaries\Win64'
  $codeSet = Get-CodeSet $wanted $loaderSpec
  $script:ServerId = $serverId
  if ($chosen) { Write-Json (Join-Path $KitHome "$serverId\accepted.json") @($codeSet) }  # the ticked list was the answer
  else { Confirm-CodeSet $cfg $serverId $codeSet }
  if ($cfg) { Install-ServerShortcuts $cfg $serverId $game }

  $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('moonpool-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $script:Work | Out-Null
  $plan = New-Object System.Collections.Generic.List[object]   # files to place
  $expectedFiles = @{}                                         # mod name -> every file that proves it current
  $staleKeys = New-Object System.Collections.Generic.List[string]
  $desired = @{}                                               # target path (lower) -> owner entry
  $changes = New-Object System.Collections.Generic.List[string]
  $conflicts = New-Object System.Collections.Generic.List[string]
  $held = New-Object System.Collections.Generic.List[object]   # files there already, not placed here

  # A mod is current when its archive and install place are the ones recorded and every file that archive
  # put or found in place still matches, whether it was placed here or already there.
  function Test-ModCurrent($Mod) {
    $key = "$serverId/$($Mod.Name)"
    if (-not $ledger.mods.ContainsKey($key)) { return $false }
    $record = $ledger.mods[$key]
    if ($record.archive -ne $Mod.ArchiveSha -or -not $Mod.ArchiveSha -or $record.identity -ne $Mod.Identity) { return $false }
    $expected = @($record.files)
    if ($expected.Count -eq 0) { return $false }
    foreach ($e in $expected) {
      if (-not (Test-Path -LiteralPath ([string]$e.path)) -or (Get-Sha256 ([string]$e.path)) -ne [string]$e.sha256) { return $false }
    }
    foreach ($path in @($ledger.files.Keys | Where-Object { $ledger.files[$_].server -eq $serverId -and $ledger.files[$_].mod -eq $Mod.Name })) {
      $desired[$path] = $ledger.files[$path]
    }
    $expectedFiles[$Mod.Name] = $expected
    return $true
  }

  function Add-ToPlan([string]$ModName, [string]$Base, $Files) {
    $proof = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Files) {
      $target = Join-Path $Base $f.Rel
      $key = $target.ToLowerInvariant()
      $exists = Test-Path -LiteralPath $target
      $now = if ($exists) { Get-Sha256 $target } else { '' }
      $ours = $ledger.files.ContainsKey($key) -and (-not $exists -or $now -eq $ledger.files[$key].sha256)
      $same = $exists -and ($now -eq $f.Sha256)
      # The loader's settings are the player's once they exist and differ from what this launcher
      # placed: never replaced then, and never part of what proves the loader current. A copy still
      # byte for byte the one placed is the server's, so the server's new copy replaces it.
      $isConfig = ($ModName -eq 'UE4SS' -and $LoaderConfig -contains $f.Rel)
      if ($isConfig -and $exists -and -not ($ours -and -not $same)) {
        if ($ours) { $desired[$key] = $ledger.files[$key] }
        continue
      }
      if (-not $isConfig) { $proof.Add(@{ path = $key; sha256 = $f.Sha256 }) }
      if ($exists -and -not $ours) {
        # A file already identical is used without being claimed: only what this
        # launcher placed is ever removed.
        if ($same) { continue }
        if (-not $Adopt) {
          $conflicts.Add("$target (for $ModName)")
          # A file sitting where this launcher parks one of its own switched-off files is never offered:
          # replacing it would leave two copies for the on/off switch to choose between.
          if (Test-Path -LiteralPath "$target.moonpool-off") { continue }
          $held.Add([pscustomobject]@{ Key = $key; Entry = @{ sha256 = $f.Sha256; server = $serverId; mod = $ModName }; Path = $f.Path; Target = $target; Mod = $ModName })
          continue
        }
      }
      if ($desired.ContainsKey($key) -and [string]$desired[$key].mod -ne $ModName) {
        Fail "the server's mods $($desired[$key].mod) and $ModName both install $target; ask the admin to keep one, nothing changed, game not started"
      }
      $desired[$key] = @{ sha256 = $f.Sha256; server = $serverId; mod = $ModName }
      if (-not $same) { $plan.Add([pscustomobject]@{ Path = $f.Path; Target = $target }) }
    }
    $expectedFiles[$ModName] = $proof.ToArray()
  }

  $script:UiSteps = ($wanted | Measure-Object).Count
  if ($loaderSpec) { $script:UiSteps += 1 }
  foreach ($mod in $wanted) {
    $key = "$serverId/$($mod.Name)"
    $script:UiStep++
    if (Test-ModCurrent $mod) { continue }
    $staleKeys.Add($key)
    Set-Status "Downloading $($mod.Name) ($script:UiStep of $script:UiSteps)" ([int](100 * ($script:UiStep - 1) / $script:UiSteps))
    $archive = Get-ModArchive $mod $script:Work
    $files = Expand-ModArchive $mod $archive $script:Work
    Add-ToPlan $mod.Name (Get-ModTargets $mod $game) $files
    $label = $mod.Name
    if ($mod.Version) { $label = "$($mod.Name) $($mod.Version)" }
    if ($ledger.mods.ContainsKey($key)) {
      $old = $ledger.mods[$key].version
      if ($old -and $old -ne $mod.Version) { $changes.Add("updating $($mod.Name) $old -> $($mod.Version)") }
      else { $changes.Add("repairing $label") }
    } else { $changes.Add("installing $label") }
  }
  $loaderMod = $null
  if ($loaderSpec) {
    $loaderMod = [pscustomobject]@{ Name = 'UE4SS'; Identity = 'loader'; Version = [string](Get-Prop $loaderSpec 'asset' ''); ArchiveSha = ([string](Get-Prop $loaderSpec 'sha256' '')).ToLowerInvariant() }
    if (-not (Test-ModCurrent $loaderMod)) {
      $staleKeys.Add("$serverId/UE4SS")
      $script:UiStep = $script:UiSteps
      Set-Status "Downloading the mod loader ($script:UiStep of $script:UiSteps)" ([int](100 * ($script:UiStep - 1) / $script:UiSteps))
      $loaderFiles = Get-LoaderFiles $loaderSpec $script:Work
      $before = $plan.Count
      Add-ToPlan 'UE4SS' $win64 $loaderFiles
      if ($plan.Count -gt $before) { $changes.Add("installing the UE4SS loader ($([string](Get-Prop $loaderSpec 'asset' 'pinned')))") }
    }
  }
  if ($conflicts.Count -gt $held.Count) {
    Fail ("this PC already has files the server wants to replace, installed another way: " + ($conflicts -join ', ') +
      "; remove them yourself, or run again with -Adopt to replace them with the server's versions (no copy is kept); nothing changed, game not started")
  }
  if ($conflicts.Count -gt 0) {
    # Files already where the server's go that this launcher did not place: the player says whether
    # to replace them, and a copy of each is kept outside Moonpool's own folder, which an uninstall removes.
    $aside = Join-Path $env:LOCALAPPDATA ('Moonpool-replaced\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $gameRoot = $game.TrimEnd('\') + '\'
    $relative = { param($p) if ($p.StartsWith($gameRoot, [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($gameRoot.Length) } else { Split-Path -Leaf $p } }
    $text = "This PC already has files where this server's mods go, and Moonpool didn't put them there:`n`n" +
      (($held | ForEach-Object { "  - $(& $relative $_.Target) (for $($_.Mod))" }) -join "`n") +
      "`n`nThey may be an older copy of the same mod or loader, installed by hand or by another tool. " +
      "Moonpool can keep a copy of them in $aside and install the server's versions. It doesn't put them back by itself.`n`nReplace them?"
    if ($Approve) { $yes = & $Approve $text } else { $yes = Show-Question $text 'Files already in the game folder' 'Replace and play' 'Cancel' }
    if (-not $yes) {
      Fail ("this PC already has files the server wants to replace, installed another way: " + ($conflicts -join ', ') +
        "; nothing changed, game not started") 3
    }
    foreach ($h in $held) {
      $copy = Join-Path $aside (& $relative $h.Target)
      New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
      Copy-Item -LiteralPath $h.Target -Destination $copy -Force
      $desired[$h.Key] = $h.Entry
      $plan.Add([pscustomobject]@{ Path = $h.Path; Target = $h.Target })
    }
    $changes.Add("replacing $($held.Count) file(s) that were already there; copies in $aside")
  }

  # Everything managed locally that this server does not want goes: another server's
  # set, a mod the admin dropped, the loader when nothing needs it. Only unchanged
  # files are removed; a file the player edited is left and named.
  $gone = Get-Removals $ledger $desired $false
  $removals = $gone.Remove
  foreach ($path in $gone.Kept) { Say "leaving ${path}: it was changed since this launcher placed it" }
  $keepNames = @($wanted | ForEach-Object { $_.Name })
  if ($loaderMod) { $keepNames += 'UE4SS' }
  $goneMods = @($ledger.mods.Keys | Where-Object {
    $k = $_; $s = $k.Split('/')[0]; $n = $k.Substring($s.Length + 1)
    -not ($s -eq $serverId -and ($keepNames -contains $n))
  })
  foreach ($k in $goneMods) {
    $s = $k.Split('/')[0]; $n = $k.Substring($s.Length + 1)
    # A loader the player already had leaves only a record behind; nothing of theirs goes.
    if (-not @($ledger.files.Keys | Where-Object { $ledger.files[$_].mod -eq $n })) { continue }
    if ($s -eq $serverId) { $changes.Add("removing $n (no longer on this server)") }
    else { $changes.Add("removing $n (another server's mod)") }
  }

  $changed = $plan.Count -gt 0 -or $removals.Count -gt 0 -or $goneMods.Count -gt 0
  if (-not $changed) {
    Say ("mods up to date (" + $wanted.Count + " mod(s) checked)")
  } else {
    foreach ($c in $changes) { Say $c }
    # The intent is recorded first: an interrupted run leaves every file it may have
    # placed owned and every changing mod not current, so the next run repairs it.
    $ledgerBefore = $null
    if (Test-Path -LiteralPath $ledgerPath) { $ledgerBefore = [IO.File]::ReadAllText($ledgerPath) }
    foreach ($path in @($desired.Keys)) { $ledger.files[$path] = $desired[$path] }
    foreach ($k in $staleKeys) { $ledger.mods.Remove($k) }
    Write-Ledger $ledgerPath $ledger
    Set-Status 'Installing mods' 100
    $script:UiInstalling = $true
    try { Install-Plan $plan $removals $script:Work }
    catch {
      if ($null -ne $ledgerBefore) { [IO.File]::WriteAllText($ledgerPath, $ledgerBefore) }
      else { Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue }
      throw
    }
    [void](Remove-EmptyParents $removals)
    foreach ($path in @($ledger.files.Keys)) { if (-not $desired.ContainsKey($path)) { $ledger.files.Remove($path) } }
    foreach ($k in $goneMods) { $ledger.mods.Remove($k) }
  }
  foreach ($path in @($desired.Keys)) { $ledger.files[$path] = $desired[$path] }
  foreach ($mod in $wanted) { Set-ModRecord $ledger $serverId $mod $expectedFiles }
  if ($loaderMod) { Set-ModRecord $ledger $serverId $loaderMod $expectedFiles }
  if ($changed -or $staleKeys.Count -gt 0) { Write-Ledger $ledgerPath $ledger }

  $session = Get-Prop $manifest 'session' $null
  $url = "steam://rungameid/$appId"
  if ($session -and [string](Get-Prop $session 'lobby_id' '') -match '^[0-9]+$' -and [string](Get-Prop $session 'host_steamid' '') -match '^[0-9]+$') {
    $url = "steam://joinlobby/$appId/$($session.lobby_id)/$($session.host_steamid)"
  }
  Write-Host "moonpool: starting the game through $url"
  $script:UiInstalling = $false
  Set-Status 'Starting Subnautica 2 through Steam' 100
  if ($Launch) { & $Launch $url } else { Start-Process $url }
  # Steam gives back no process, so the game is watched for by name.
  $deadline = [DateTime]::UtcNow.AddSeconds($StartWait)
  while (-not (Test-GameRunning)) {
    if ([DateTime]::UtcNow -gt $deadline) {
      $left = @(Switch-MoonpoolMods $false); $script:ModsOn = $false
      if ($left.Count -gt 0) { Fail ("Subnautica 2 did not start in time and these stayed on: " + ($left -join ', ') + "; run the Subnautica 2 (without Moonpool mods) shortcut") }
      Fail "Subnautica 2 did not start in time, so Moonpool turned its mods off again; if it starts now it runs without them"
    }
    if ($script:Ui) { [Windows.Forms.Application]::DoEvents() }
    Start-Sleep -Milliseconds 500
  }
  Close-Window
  Say "Subnautica 2 is running; Moonpool's mods turn off when it closes"
  while (Test-GameRunning) { Start-Sleep -Seconds 2 }
  $left = @(Switch-MoonpoolMods $false)
  $script:ModsOn = $false
  if ($left.Count -gt 0) { Fail ("could not turn Moonpool's mods off, still in use: " + ($left -join ', ') + '; run the Subnautica 2 (without Moonpool mods) shortcut') }
  Say "Subnautica 2 closed; Moonpool's mods are off"
}

try {
  Invoke-Join
  exit 0
} catch {
  $code = 1
  if ($_.Exception.Data.Contains('sn2code')) { $code = [int]$_.Exception.Data['sn2code'] }
  $script:UiCancelled = $false
  Write-Host "moonpool: $($_.Exception.Message)"
  Write-Log ("failed: $($_.Exception.Message) | " + ($_.ScriptStackTrace -replace '\r?\n', ' < '))
  # A link or shortcut has no console left open to read this in. Code 3 is the player's own
  # choice (declined, or closed the window), which needs no message.
  if ($code -ne 3 -and -not $script:FirstWindowShown -and ($Link -or $Server -or $DisableMoonpoolMods -or $Uninstall) -and -not $Launch -and -not $env:SN2_JOIN_NO_DIALOG) {
    $heading = "Couldn't start with mods"
    if ($Uninstall) { $heading = "Couldn't uninstall Moonpool" } elseif ($DisableMoonpoolMods) { $heading = "Couldn't turn Moonpool's mods off" }
    Show-Notice $heading ($_.Exception.Message + "`n`nThe details are in %LOCALAPPDATA%\moonpool\moonpool.log; send that file to the server's host.")
  }
  exit $code
} finally {
  Close-Window
  if ($script:ModsOn) { [void](Switch-MoonpoolMods $false) }
  if ($script:Lock) { $script:Lock.ReleaseMutex() }
  if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
  }
}
