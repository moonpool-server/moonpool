#Requires -Version 5.1
# Plain PowerShell tests for client/moonpool/moonpool.ps1 (no Pester needed).
# Builds a fake Steam tree with two libraries, the game in the non-default one,
# and fake servers publishing schema 3 manifests and archives as file:// addresses.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File client/tests/moonpool.tests.ps1
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Script = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\moonpool\moonpool.ps1')).Path
$env:SN2_JOIN_NO_DIALOG = '1'  # no window or message box on the desktop of whoever runs these
$env:MOONPOOL_CLASSES_ROOT = 'HKCU:\Software\moonpool-tests'  # the link handler these runs write, never the user's
$failures = 0
$passes = 0

function Check([bool]$Cond, [string]$What) {
  if ($Cond) { $script:passes++; Write-Host "  ok   $What" }
  else { $script:failures++; Write-Host "  FAIL $What" }
}

function Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

# A zip whose members are the given relative paths with the given content version.
function New-Zip([string]$Out, [string[]]$Members, [string]$Version = '1') {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('sn2zip-' + [guid]::NewGuid().ToString('N'))
  foreach ($m in $Members) {
    $p = Join-Path $dir $m
    New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
    Set-Content -LiteralPath $p -Value "$m v$Version" -NoNewline
  }
  if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
  Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $Out
  Remove-Item -LiteralPath $dir -Recurse -Force
}

# A zip written entry by entry, for names no folder can hold. $Declare overstates an entry's
# unpacked size in the central directory; $Links makes entries Unix symlinks to the given target.
function New-RawZip([string]$Out, [string[]]$Names, [hashtable]$Declare = @{}, [hashtable]$Links = @{}, [hashtable]$Bodies = @{}) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
  $z = [IO.Compression.ZipFile]::Open($Out, 'Create')
  foreach ($n in $Names) {
    $e = $z.CreateEntry($n); $body = 'x'
    if ($Bodies.ContainsKey($n)) { $body = $Bodies[$n] }
    if ($Links.ContainsKey($n)) { $e.ExternalAttributes = [int](0xA1FF -shl 16); $body = $Links[$n] }  # S_IFLNK | 0777
    $s = New-Object IO.StreamWriter($e.Open()); $s.Write($body); $s.Dispose()
  }
  $z.Dispose()
  if ($Declare.Count -eq 0 -and $Links.Count -eq 0) { return }
  $b = [IO.File]::ReadAllBytes($Out); $patched = 0
  for ($i = 0; $i -le $b.Length - 46; $i++) {
    if ($b[$i] -ne 0x50 -or $b[$i + 1] -ne 0x4b -or $b[$i + 2] -ne 1 -or $b[$i + 3] -ne 2) { continue }
    $name = [Text.Encoding]::UTF8.GetString($b, $i + 46, [BitConverter]::ToUInt16($b, $i + 28))
    if ($Links.ContainsKey($name)) { $b[$i + 5] = 3; $patched++ }  # made by Unix, as Info-ZIP writes a symlink
    if ($Declare.ContainsKey($name)) { [BitConverter]::GetBytes([uint32]$Declare[$name]).CopyTo($b, $i + 24); $patched++ }
  }
  if ($patched -ne $Declare.Count + $Links.Count) { throw "New-RawZip patched $patched of the entries it was asked to" }
  [IO.File]::WriteAllBytes($Out, $b)
}

function New-World {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('moonpool-' + [guid]::NewGuid().ToString('N'))
  $steam = Join-Path $root 'Steam'
  $lib2 = Join-Path $root 'Games Lib'
  $game = Join-Path $lib2 'steamapps\common\Subnautica2'
  New-Item -ItemType Directory -Path (Join-Path $steam 'steamapps') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $game 'Subnautica2\Content\Paks') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $game 'Subnautica2\Binaries\Win64') -Force | Out-Null
  $exe = Join-Path $game 'Subnautica2\Binaries\Win64\Subnautica2-Win64-Test.exe'
  Set-Content -LiteralPath $exe -Value 'not really the game' -NoNewline
  $vdf = @"
"libraryfolders"
{
	"0"
	{
		"path"		"$($steam -replace '\\', '\\')"
		"apps" { "228980" "1" }
	}
	"1"
	{
		"path"		"$($lib2 -replace '\\', '\\')"
		"apps" { "1962700" "1" }
	}
}
"@
  Set-Content -LiteralPath (Join-Path $steam 'steamapps\libraryfolders.vdf') -Value $vdf
  Set-Content -LiteralPath (Join-Path $lib2 'steamapps\appmanifest_1962700.acf') -Value "`"AppState`"`n{`n`t`"appid`"`t`t`"1962700`"`n`t`"installdir`"`t`t`"Subnautica2`"`n`t`"buildid`"`t`t`"4242`"`n`t`"BetaKey`"`t`t`"experimental`"`n}"

  $srv = Join-Path $root 'server'
  New-Item -ItemType Directory -Path $srv | Out-Null
  New-Zip (Join-Path $srv 'Foo.zip') @('Foo\Scripts\main.lua', 'Foo\Scripts\lib.lua')
  New-Zip (Join-Path $srv 'Bar.zip') @('Scripts\main.lua')
  New-Zip (Join-Path $srv 'Baz.zip') @('Baz.pak', 'Baz.ucas', 'Baz.utoc')
  New-Zip (Join-Path $srv 'ue4ss.zip') @('dwmapi.dll', 'ue4ss\UE4SS.dll', 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt')
  New-Item -ItemType Directory -Path (Join-Path $root 'Downloads') | Out-Null

  $w = [pscustomobject]@{
    Root = $root; Steam = $steam; Game = $game; Server = $srv; Exe = $exe
    Win64 = (Join-Path $game 'Subnautica2\Binaries\Win64')
    Mods = (Join-Path $game 'Subnautica2\Binaries\Win64\ue4ss\Mods')
    Paks = (Join-Path $game 'Subnautica2\Content\Paks\~mods')
    Manifest = (Join-Path $srv 'mods.json')
    Downloads = (Join-Path $root 'Downloads')
  }
  return $w
}

function Mod($w, [string]$Name, [string]$Zip, [string]$Folder, [string]$Prefix, [bool]$Required = $true,
             [string]$Version = '1.0', [string]$Kind = 'ue4ss', [bool]$Manual = $false, [string]$Page = '',
             [bool]$Native = $false, [string[]]$Algorithms = @('sha256')) {
  $path = Join-Path $w.Server $Zip
  $url = ''
  if (-not $Manual) { $url = ([Uri]$path).AbsoluteUri }
  $hashes = @($Algorithms | ForEach-Object { [ordered]@{ algorithm = $_; value = (Get-FileHash -Algorithm $_ -LiteralPath $path).Hash.ToLowerInvariant() } })
  return [ordered]@{
    name = $Name; version = $Version; required = $Required; kind = $Kind; folder = $Folder; prefix = $Prefix
    native = $Native
    source = [ordered]@{ type = 'local'; page = $Page; url = $url; file_name = $Zip; hashes = $hashes }
  }
}

function Write-Manifest($w, $Mods, [string]$ServerId = 'server-a', [bool]$Loader = $true, [string[]]$Allowed = $null,
                        [string]$Build = '4242', [string]$Branch = 'experimental') {
  if ($null -eq $Allowed) { $Allowed = @((Sha $w.Exe)) }
  $m = [ordered]@{
    schema = 3; app_id = '1962700'
    game = [ordered]@{ branch = $Branch; buildid = $Build }
    server = [ordered]@{ id = $ServerId; name = "Server $ServerId" }
    session = [ordered]@{ lobby_id = '16'; host_steamid = '76561198000000000' }
    mods = @($Mods)
  }
  if ($Loader) {
    $m.ue4ss = [ordered]@{ channel = 'pinned'; asset = 'ue4ss.zip'; url = 'ue4ss.zip'
                           sha256 = (Sha (Join-Path $w.Server 'ue4ss.zip')); allowed_builds = @($Allowed) }
  }
  Set-Content -LiteralPath $w.Manifest -Value ($m | ConvertTo-Json -Depth 10) -Encoding UTF8
}

# Runs the launcher in a child PowerShell 5.1 so its exit code is real; the
# running-game check, the launch and the pages opened are stubbed through files.
# The launch starts a fake game that is seen running once, when the game folder is
# listed into Session, runs $Game, and has exited by the next look.
function Invoke-Join($w, [switch]$GameRunning, [string]$Extra = '', [string]$Answer = '$true', [string]$Scan = "`$p -notmatch 'Flagged'",
                     [string]$Game = '', [switch]$NoStart, [string]$LaunchExtra = '', [switch]$Shortcuts) {
  $launchLog = Join-Path $w.Root 'launched.txt'
  $pageLog = Join-Path $w.Root 'page.txt'
  $askLog = Join-Path $w.Root 'asked.txt'
  $gameFlag = Join-Path $w.Root 'game.txt'
  $sessionLog = Join-Path $w.Root 'session.txt'
  foreach ($f in @($launchLog, $pageLog, $askLog, $gameFlag, $sessionLog)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f } }
  if ($GameRunning) { Set-Content -LiteralPath $gameFlag -Value 'up' }
  $start = "Set-Content -LiteralPath '$gameFlag' -Value 'up'"; if ($NoStart) { $start = ''; $Extra += ' -StartWait 1' }
  $noShortcuts = if ($Shortcuts) { '' } else { '-NoShortcuts' }
  $running = "if (Test-Path -LiteralPath '$gameFlag') { Remove-Item -LiteralPath '$gameFlag'; Get-ChildItem -LiteralPath '$($w.Game)' -Recurse -File -Name | Set-Content -LiteralPath '$sessionLog'; $Game; `$true } else { `$false }"
  $cmd = "`$env:LOCALAPPDATA='$($w.Root)'; & '$Script' -ManifestUrl '$(([Uri]$w.Manifest).AbsoluteUri)' -SteamRoot '$($w.Steam)' " +
         "-Downloads '$($w.Downloads)' -IsGameRunning { $running } -Launch { param(`$u) Set-Content -LiteralPath '$launchLog' -Value `$u; $start; $LaunchExtra } " +
         "-OpenPage { param(`$u) Set-Content -LiteralPath '$pageLog' -Value `$u } -Approve { param(`$q) Set-Content -LiteralPath '$askLog' -Value `$q; $Answer } -OpenFriend { param(`$u) } -ScanFile { param(`$p) $Scan } $noShortcuts $Extra; exit `$LASTEXITCODE"
  $ErrorActionPreference = 'Continue'  # a launcher that dies writing to stderr is a failed check, not a stopped suite
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
  $launched = $null; $page = $null; $asked = ''; $session = @()
  if (Test-Path -LiteralPath $askLog) { $asked = (Get-Content -LiteralPath $askLog -Raw) }
  if (Test-Path -LiteralPath $launchLog) { $launched = (Get-Content -LiteralPath $launchLog -Raw).Trim() }
  if (Test-Path -LiteralPath $pageLog) { $page = (Get-Content -LiteralPath $pageLog -Raw).Trim() }
  if (Test-Path -LiteralPath $sessionLog) { $session = @(Get-Content -LiteralPath $sessionLog) }
  return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out; Launched = $launched; Page = $page; Asked = $asked; Session = $session }
}

# The files that make Moonpool's mods load, relative to the game folder, and whether each is on now.
$Activation = @('Subnautica2\Binaries\Win64\dwmapi.dll', 'Subnautica2\Binaries\Win64\ue4ss\Mods\Foo\enabled.txt',
                'Subnautica2\Content\Paks\~mods\Baz.pak', 'Subnautica2\Content\Paks\~mods\Baz.ucas', 'Subnautica2\Content\Paks\~mods\Baz.utoc')
function All-Off($w) { -not @($Activation | Where-Object { (Test-Path -LiteralPath (Join-Path $w.Game $_)) -or -not (Test-Path -LiteralPath (Join-Path $w.Game "$_.moonpool-off")) }).Count }
function All-On($w) { -not @($Activation | Where-Object { -not (Test-Path -LiteralPath (Join-Path $w.Game $_)) -or (Test-Path -LiteralPath (Join-Path $w.Game "$_.moonpool-off")) }).Count }

function Snapshot([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return '' }
  (Get-ChildItem -LiteralPath $Dir -File -Recurse | Sort-Object FullName | ForEach-Object { "$($_.FullName)=$(Sha $_.FullName)@$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
}

function Text([string]$Path) { [IO.File]::ReadAllText($Path) }

$worlds = @()
try {
  Write-Host 'fresh PC: a required UE4SS mod, an optional one and the loader go in; the lobby join is used'
  $w = New-World; $worlds += $w
  Write-Manifest $w @((Mod $w 'Foo' 'Foo.zip' 'Foo' 'Foo'), (Mod $w 'Bar' 'Bar.zip' 'Bar' '' $false '2.0'))
  $r = Invoke-Join $w
  Check ($r.Code -eq 0) "exit 0 (got $($r.Code)): $($r.Out.Trim())"
  Check ((Text (Join-Path $w.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v1') 'Foo placed from its folder inside the archive'
  Check ($r.Session -contains 'Subnautica2\Binaries\Win64\ue4ss\Mods\Foo\enabled.txt') 'Foo is enabled while the game runs'
  Check ((Text (Join-Path $w.Mods 'Bar\Scripts\main.lua')) -eq 'Scripts\main.lua v1') 'optional Bar installed by default from a root-level archive'
  Check (($r.Session -contains 'Subnautica2\Binaries\Win64\dwmapi.dll') -and (Test-Path -LiteralPath (Join-Path $w.Win64 'ue4ss\UE4SS.dll'))) 'the loader is placed beside the executable'
  Check ($r.Out -match 'installing Foo 1\.0' -and $r.Out -match 'installing Bar 2\.0' -and $r.Out -match 'installing the UE4SS loader') 'says what it installed'
  Check ($r.Launched -eq 'steam://joinlobby/1962700/16/76561198000000000') "live lobby join used (got '$($r.Launched)')"
  Check (-not (Test-Path -LiteralPath (Join-Path $w.Steam 'steamapps\common'))) 'nothing written to the default library'
  $ledger = Get-Content -LiteralPath (Join-Path $w.Root 'moonpool\owned.json') -Raw | ConvertFrom-Json
  Check (@($ledger.files.PSObject.Properties).Count -eq 9) "the ledger owns every placed file (got $(@($ledger.files.PSObject.Properties).Count))"

  Write-Host 'second run with nothing changed writes nothing and downloads nothing'
  $before = Snapshot $w.Win64
  Remove-Item -LiteralPath (Join-Path $w.Server 'ue4ss.zip')   # a download now would fail
  Start-Sleep -Milliseconds 50
  $r = Invoke-Join $w
  Check ($r.Code -eq 0) "exit 0 (got $($r.Code)): $($r.Out.Trim())"
  Check ((Snapshot $w.Win64) -eq $before) 'tree unchanged (names, hashes, timestamps)'
  Check ($r.Out -match 'mods up to date \(2 mod\(s\) checked\)') 'says up to date'
  New-Zip (Join-Path $w.Server 'ue4ss.zip') @('dwmapi.dll', 'ue4ss\UE4SS.dll', 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt')

  Write-Host 'a new version on the server is an update, named with both versions'
  New-Zip (Join-Path $w.Server 'Foo.zip') @('Foo\Scripts\main.lua', 'Foo\Scripts\lib.lua') '2'
  Write-Manifest $w @((Mod $w 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '1.1'), (Mod $w 'Bar' 'Bar.zip' 'Bar' '' $false '2.0'))
  $r = Invoke-Join $w
  Check ($r.Code -eq 0 -and $r.Out -match 'updating Foo 1\.0 -> 1\.1') "update named (got: $($r.Out.Trim()))"
  Check ((Text (Join-Path $w.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v2') 'new content in place'

  Write-Host 'an optional mod can be left out, the choice is remembered, and taken back'
  $r = Invoke-Join $w -Extra "-Skip 'Bar'"
  Check ($r.Code -eq 0 -and $r.Out -match 'removing Bar') "skip removes Bar (got: $($r.Out.Trim()))"
  Check (-not (Test-Path -LiteralPath (Join-Path $w.Mods 'Bar'))) 'Bar folder gone'
  $r = Invoke-Join $w
  Check ($r.Code -eq 0 -and $r.Out -match 'leaving out optional mod Bar' -and -not (Test-Path -LiteralPath (Join-Path $w.Mods 'Bar'))) 'the choice holds on the next run'
  $r = Invoke-Join $w -Extra "-Keep 'Bar'"
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $w.Mods 'Bar\Scripts\main.lua'))) '-Keep takes it back'

  Write-Host 'an optional mod the host set default_on false starts left out, until the player takes it'
  $wd = New-World; $worlds += $wd
  $bar = Mod $wd 'Bar' 'Bar.zip' 'Bar' '' $false; $bar.default_on = $false
  Write-Manifest $wd @((Mod $wd 'Foo' 'Foo.zip' 'Foo' 'Foo'), $bar)
  $r = Invoke-Join $wd
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $wd.Mods 'Foo')) -and -not (Test-Path -LiteralPath (Join-Path $wd.Mods 'Bar')) -and $r.Asked -notmatch 'Bar') "a first join leaves it out and does not ask about it (got: $($r.Out.Trim()))"
  $r = Invoke-Join $wd -Extra "-Keep 'Bar'"
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $wd.Mods 'Bar\Scripts\main.lua'))) 'taking it installs it'
  $r = Invoke-Join $wd
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $wd.Mods 'Bar\Scripts\main.lua'))) 'and the choice holds over the default'

  Write-Host 'a mod the admin dropped is removed; a file the player edited is left alone'
  Set-Content -LiteralPath (Join-Path $w.Mods 'Bar\Scripts\main.lua') -Value 'my own tweak' -NoNewline
  Write-Manifest $w @((Mod $w 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '1.1'))
  $r = Invoke-Join $w
  Check ($r.Code -eq 0 -and $r.Out -match 'removing Bar \(no longer on this server\)') 'drop named'
  Check ((Test-Path -LiteralPath (Join-Path $w.Mods 'Bar\Scripts\main.lua')) -and -not (Test-Path -LiteralPath (Join-Path $w.Mods 'Bar\enabled.txt'))) 'edited file kept, unchanged enabled.txt removed'
  Check ($r.Out -match 'leaving .*main\.lua: it was changed') 'says which file it left'
  Remove-Item -LiteralPath (Join-Path $w.Mods 'Bar') -Recurse -Force

  Write-Host 'joining another server swaps the set: its pak mod goes in, the first server''s mod and loader go out'
  Write-Manifest $w @((Mod $w 'Baz' 'Baz.zip' 'Baz' 'Baz' $true '3' 'pak')) 'server-b' $false
  $r = Invoke-Join $w
  Check ($r.Code -eq 0) "exit 0 (got $($r.Code)): $($r.Out.Trim())"
  Check ((Get-ChildItem -LiteralPath $w.Paks -File).Count -eq 3) 'the pak trio is in ~mods'
  Check (-not (Test-Path -LiteralPath (Join-Path $w.Mods 'Foo'))) "the other server's mod is gone"
  Check (-not (Test-Path -LiteralPath (Join-Path $w.Win64 'dwmapi.dll')) -and -not (Test-Path -LiteralPath (Join-Path $w.Win64 'ue4ss'))) 'the loader is gone when nothing needs it'
  Check ($r.Out -match "removing Foo \(another server's mod\)") 'says whose mod it removed'
  Check (@(Get-ChildItem -LiteralPath $w.Win64 -Recurse -File -Filter '*.moonpool-off').Count -eq 0) "the first server's files went whole, none left behind switched off"
  Write-Manifest $w @((Mod $w 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '1.1'))
  $r = Invoke-Join $w
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $w.Mods 'Foo\Scripts\main.lua')) -and -not (Test-Path -LiteralPath $w.Paks)) 'back on the first server: its set returns, the pak goes'

  Write-Host 'a server that drops its last mod: an empty list clears the set and still joins'
  Write-Manifest $w @() 'server-a' $false
  $r = Invoke-Join $w
  Check ($r.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $w.Mods 'Foo')) -and -not (Test-Path -LiteralPath (Join-Path $w.Win64 'dwmapi.dll'))) "everything it placed is gone (got $($r.Code)): $($r.Out.Trim())"
  Check ($r.Launched -eq 'steam://joinlobby/1962700/16/76561198000000000') 'and it joins'

  Write-Host 'a mod from a signed-in site: the page opens, the plain download in Downloads is verified and installed'
  $w2 = New-World; $worlds += $w2
  Write-Manifest $w2 @((Mod $w2 'Manual' 'Foo.zip' 'Foo' 'Foo' $true '1' 'ue4ss' $true 'https://nexus.test/mods/1'))
  $r = Invoke-Join $w2
  Check ($r.Code -ne 0 -and $r.Page -eq 'https://nexus.test/mods/1') "page opened once (got '$($r.Page)')"
  Check ($r.Out -match 'download Foo\.zip from https://nexus\.test/mods/1') 'one line names the file and the page'
  Check ($null -eq $r.Launched -and -not (Test-Path -LiteralPath $w2.Mods)) 'nothing placed, game not started'
  Set-Content -LiteralPath (Join-Path $w2.Downloads 'Foo.zip') -Value 'wrong bytes'
  $r = Invoke-Join $w2
  Check ($r.Code -ne 0 -and $r.Out -match 'Foo\.zip failed its sha256 check') 'a wrong download is refused'
  Copy-Item -LiteralPath (Join-Path $w2.Server 'Foo.zip') -Destination (Join-Path $w2.Downloads 'Foo.zip') -Force
  $r = Invoke-Join $w2
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $w2.Mods 'Foo\Scripts\main.lua'))) 'the verified download installs'

  Write-Host 'files already there another way are replaced only after a yes, with a copy kept, or with -Adopt'
  $w3 = New-World; $worlds += $w3
  $hand = Join-Path $w3.Mods 'Foo\Scripts\main.lua'
  New-Item -ItemType Directory -Path (Split-Path -Parent $hand) -Force | Out-Null
  Set-Content -LiteralPath $hand -Value 'installed by hand' -NoNewline
  Write-Manifest $w3 @((Mod $w3 'Foo' 'Foo.zip' 'Foo' 'Foo'))
  $noReplace = '($q -notmatch ''already has files'')'
  $r = Invoke-Join $w3 -Answer $noReplace
  Check ($r.Code -eq 3 -and $r.Out -match 'installed another way' -and $r.Asked -match 'Foo\\Scripts\\main\.lua \(for Foo\)') "the question names the file; no keeps it (code $($r.Code), asked: $($r.Asked))"
  Check ((Text $hand) -eq 'installed by hand' -and $null -eq $r.Launched -and -not (Test-Path -LiteralPath (Join-Path $w3.Root 'Moonpool-replaced'))) 'nothing changed, no copy, game not started'
  $r = Invoke-Join $w3
  $copies = @(Get-ChildItem -LiteralPath (Join-Path $w3.Root 'Moonpool-replaced') -Recurse -File -Filter main.lua)
  Check ($r.Code -eq 0 -and (Text $hand) -eq 'Foo\Scripts\main.lua v1') 'yes lets the server version take over'
  Check ($copies.Count -eq 1 -and (Text $copies[0].FullName) -eq 'installed by hand') 'a copy of the replaced file is kept outside the launcher folder'
  $w3b = New-World; $worlds += $w3b
  $hand = Join-Path $w3b.Mods 'Foo\Scripts\main.lua'
  New-Item -ItemType Directory -Path (Split-Path -Parent $hand) -Force | Out-Null
  Set-Content -LiteralPath $hand -Value 'installed by hand' -NoNewline
  Write-Manifest $w3b @((Mod $w3b 'Foo' 'Foo.zip' 'Foo' 'Foo'))
  $r = Invoke-Join $w3b -Extra '-Adopt' -Answer $noReplace
  Check ($r.Code -eq 0 -and (Text $hand) -eq 'Foo\Scripts\main.lua v1' -and $r.Asked -notmatch 'already has files') "-Adopt replaces without asking (code $($r.Code), asked: $($r.Asked), out: $($r.Out.Trim()))"

  Write-Host 'a loader the player already has: their settings stay, nothing is claimed, leaving the server keeps it'
  $w7 = New-World; $worlds += $w7
  $unz = Join-Path $w7.Root 'loader'; Expand-Archive -LiteralPath (Join-Path $w7.Server 'ue4ss.zip') -DestinationPath $unz
  Copy-Item -LiteralPath (Join-Path $unz 'dwmapi.dll') -Destination $w7.Win64
  Copy-Item -LiteralPath (Join-Path $unz 'ue4ss') -Destination $w7.Win64 -Recurse
  Set-Content -LiteralPath (Join-Path $w7.Win64 'ue4ss\Mods\mods.txt') -Value 'MyMod : 1' -NoNewline
  Set-Content -LiteralPath (Join-Path $w7.Win64 'ue4ss\UE4SS-settings.ini') -Value 'my settings' -NoNewline
  New-Item -ItemType Directory -Path (Join-Path $w7.Mods 'MyMod') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $w7.Mods 'MyMod\enabled.txt') -Value '' -NoNewline
  Write-Manifest $w7 @((Mod $w7 'Foo' 'Foo.zip' 'Foo' 'Foo'))
  $r = Invoke-Join $w7
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $w7.Mods 'Foo\Scripts\main.lua'))) "the mod installs beside their loader (got $($r.Code)): $($r.Out.Trim())"
  Check ((Text (Join-Path $w7.Win64 'ue4ss\Mods\mods.txt')) -eq 'MyMod : 1' -and (Text (Join-Path $w7.Win64 'ue4ss\UE4SS-settings.ini')) -eq 'my settings') 'their mods.txt and settings are untouched'
  Write-Host "a player's own loader and mods are never switched off, only Moonpool's mod is"
  $theirs = @('dwmapi.dll', 'ue4ss\Mods\mods.txt', 'ue4ss\Mods\MyMod\enabled.txt')
  function Theirs-InPlace { -not @($theirs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $w7.Win64 $_)) -or (Test-Path -LiteralPath (Join-Path $w7.Win64 "$_.moonpool-off")) }).Count }
  Check (($r.Session -contains 'Subnautica2\Binaries\Win64\ue4ss\Mods\Foo\enabled.txt') -and (Test-Path -LiteralPath (Join-Path $w7.Mods 'Foo\enabled.txt.moonpool-off'))) "Moonpool's mod was on for the session and is off after"
  Check (Theirs-InPlace) 'their proxy, mods.txt and own mod stay where they are after the session'
  $r = Invoke-Join $w7 -Extra '-DisableMoonpoolMods'
  Check ($r.Code -eq 0 -and (Theirs-InPlace)) "the mods-off shortcut leaves them too (got $($r.Code)): $($r.Out.Trim())"
  Remove-Item -LiteralPath (Join-Path $w7.Server 'ue4ss.zip')
  $r = Invoke-Join $w7
  Check ($r.Code -eq 0 -and $r.Out -match 'mods up to date') 'their loader counts as current: no download on the next run'
  New-Zip (Join-Path $w7.Server 'ue4ss.zip') @('dwmapi.dll', 'ue4ss\UE4SS.dll', 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt')
  Write-Manifest $w7 @((Mod $w7 'Baz' 'Baz.zip' 'Baz' 'Baz' $true '3' 'pak')) 'server-b' $false
  $r = Invoke-Join $w7
  Check ($r.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $w7.Mods 'Foo'))) 'leaving the server removes the mod it placed'
  Check ($r.Out -notmatch 'removing UE4SS') 'and does not claim to remove a loader it did not place'
  Check ((Test-Path -LiteralPath (Join-Path $w7.Win64 'dwmapi.dll')) -and (Test-Path -LiteralPath (Join-Path $w7.Win64 'ue4ss\UE4SS.dll')) -and (Text (Join-Path $w7.Win64 'ue4ss\Mods\mods.txt')) -eq 'MyMod : 1') 'their loader survives leaving the server'

  Write-Host "a session: Moonpool's mods are on while the game runs and off once it closes"
  $ws = New-World; $worlds += $ws
  Write-Manifest $ws @((Mod $ws 'Foo' 'Foo.zip' 'Foo' 'Foo'), (Mod $ws 'Baz' 'Baz.zip' 'Baz' 'Baz' $true '3' 'pak'))
  function Was-On($r) { -not @($Activation | Where-Object { $r.Session -notcontains $_ }).Count -and -not ($r.Session -like '*.moonpool-off') }
  $r = Invoke-Join $ws
  Check ($r.Code -eq 0 -and (Was-On $r)) "the loader, the enabled.txt and the pak trio were on while the game ran (got $($r.Code)): $($r.Out.Trim())"
  Check ((All-Off $ws) -and $r.Out -match "Moonpool's mods are off") 'and all of them are off after it closed'

  Write-Host 'the next session turns them on again without downloading anything'
  foreach ($z in @('Foo.zip', 'Baz.zip', 'ue4ss.zip')) { Rename-Item -LiteralPath (Join-Path $ws.Server $z) -NewName "$z.away" }
  $r = Invoke-Join $ws
  Check ($r.Code -eq 0 -and $r.Out -match 'mods up to date' -and (Was-On $r) -and (All-Off $ws)) "switched-off mods count as installed and current (got $($r.Code)): $($r.Out.Trim())"
  foreach ($z in @('Foo.zip', 'Baz.zip', 'ue4ss.zip')) { Rename-Item -LiteralPath (Join-Path $ws.Server "$z.away") -NewName $z }

  Write-Host 'a game that crashes, a launch that fails and a game that never starts all leave them off'
  $r = Invoke-Join $ws -Game 'Write-Host crashed'
  Check ($r.Code -eq 0 -and (Was-On $r) -and (All-Off $ws)) "a game gone at the next look still turns them off (got $($r.Code)): $($r.Out.Trim())"
  $r = Invoke-Join $ws -LaunchExtra "throw 'Steam is not running'"
  Check ($r.Code -ne 0 -and $r.Out -match 'Steam is not running' -and (All-Off $ws)) "a launch that throws turns them off (got $($r.Code)): $($r.Out.Trim())"
  $r = Invoke-Join $ws -NoStart
  Check ($r.Code -ne 0 -and $r.Out -match 'did not start in time' -and (All-Off $ws)) "a game that never appears turns them off and says so (got $($r.Code)): $($r.Out.Trim())"

  Write-Host 'a launcher that dies mid-session leaves them on; the mods-off shortcut and the next run each clear that'
  $r = Invoke-Join $ws -Game 'Stop-Process -Id $PID -Force'
  Check ((Was-On $r) -and (All-On $ws)) 'killed while the game ran, the launcher left them on'
  $r = Invoke-Join $ws -Extra '-DisableMoonpoolMods'
  Check ($r.Code -eq 0 -and (All-Off $ws) -and $r.Launched -match '^steam://rungameid/' -and $r.Out -match "Moonpool's mods are off") "-DisableMoonpoolMods turns them off and starts the plain game (got $($r.Code)): $($r.Out.Trim())"
  [void](Invoke-Join $ws -Game 'Stop-Process -Id $PID -Force')
  Write-Manifest $ws @((Mod $ws 'Foo' 'Foo.zip' 'Foo' 'Foo'), (Mod $ws 'Baz' 'Baz.zip' 'Baz' 'Baz' $true '3' 'pak')) 'server-a' $true $null '9999' 'public'
  $r = Invoke-Join $ws
  Check ($r.Code -ne 0 -and $r.Out -match 'server needs Steam branch' -and (All-Off $ws)) "the next run clears them even when it stops before the launch (got $($r.Code)): $($r.Out.Trim())"
  Write-Manifest $ws @((Mod $ws 'Foo' 'Foo.zip' 'Foo' 'Foo'), (Mod $ws 'Baz' 'Baz.zip' 'Baz' 'Baz' $true '3' 'pak'))

  Write-Host 'a second launcher started during a session is refused and changes nothing'
  $second = Join-Path $ws.Root 'second.txt'
  $r = Invoke-Join $ws -Game "& powershell -NoProfile -ExecutionPolicy Bypass -File '$Script' -DisableMoonpoolMods *> '$second'; Add-Content -LiteralPath '$second' -Value ('exit ' + `$LASTEXITCODE)"
  $b = Text $second
  Check ($b -match 'another Moonpool launcher is running' -and $b -match 'exit 2') "the second one names the first and exits 2 (got: $($b.Trim()))"
  Check ($r.Code -eq 0 -and (Was-On $r) -and (All-Off $ws)) 'the first finishes its session as usual'

  Write-Host 'a loader the player put where Moonpool switched its own off is theirs, never replaced'
  $own = Join-Path $ws.Win64 'dwmapi.dll'; $parked = "$own.moonpool-off"
  Set-Content -LiteralPath $own -Value 'the player''s own loader' -NoNewline
  $before = Sha $parked
  $r = Invoke-Join $ws
  Check ($r.Code -ne 0 -and $r.Out -match 'already has files' -and -not $r.Launched -and (Text $own) -eq 'the player''s own loader' -and (Sha $parked) -eq $before) "refused, both files as they were (got $($r.Code)): $($r.Out.Trim())"
  Remove-Item -LiteralPath $own

  Write-Host 'a game build the server has not listed is refused every session, even with the loader in place'
  Set-Content -LiteralPath $ws.Exe -Value 'the game after a Steam update' -NoNewline
  $r = Invoke-Join $ws
  Check ($r.Code -ne 0 -and $r.Out -match 'not listed for this game build' -and -not $r.Launched -and (All-Off $ws)) "refused, game not started, mods off (got $($r.Code)): $($r.Out.Trim())"

  Write-Host 'one missing file of a current mod is repaired; a removal that fails puts everything back'
  $w8 = New-World; $worlds += $w8
  Write-Manifest $w8 @((Mod $w8 'Foo' 'Foo.zip' 'Foo' 'Foo'), (Mod $w8 'Bar' 'Bar.zip' 'Bar' ''))
  $r = Invoke-Join $w8
  Remove-Item -LiteralPath (Join-Path $w8.Mods 'Foo\Scripts\lib.lua')
  $r = Invoke-Join $w8
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $w8.Mods 'Foo\Scripts\lib.lua')) -and $r.Out -match 'repairing Foo') "a missing file is noticed and restored (got: $($r.Out.Trim()))"
  New-Zip (Join-Path $w8.Server 'Foo.zip') @('Foo\Scripts\main.lua', 'Foo\Scripts\lib.lua') '3'
  Write-Manifest $w8 @((Mod $w8 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '3.0'))
  $lock = [IO.File]::Open((Join-Path $w8.Mods 'Bar\Scripts\main.lua'), 'Open', 'Read', 'Read')
  try { $r = Invoke-Join $w8 } finally { $lock.Dispose() }
  Check ($r.Code -ne 0 -and $r.Out -match 'the previous set was put back' -and $null -eq $r.Launched) "a locked file stops the run (got: $($r.Out.Trim()))"
  Check ((Text (Join-Path $w8.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v1' -and (Test-Path -LiteralPath (Join-Path $w8.Mods 'Bar\enabled.txt.moonpool-off'))) 'the update was rolled back with it, no mixed set'
  $r = Invoke-Join $w8
  Check ($r.Code -eq 0 -and (Text (Join-Path $w8.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v3' -and -not (Test-Path -LiteralPath (Join-Path $w8.Mods 'Bar'))) 'the next run finishes the change'
  Write-Host 'a release laid out the way real ones are: nested, its own enabled.txt, a sibling folder'
  New-Zip (Join-Path $w8.Server 'Nested.zip') @('Install-Nested\Nested\Scripts\main.lua', 'Install-Nested\Nested\enabled.txt', 'Install-Nested\Other\extra.lua', 'Install-Nested\README.md')
  Write-Manifest $w8 @((Mod $w8 'Nested' 'Nested.zip' 'Nested' 'Install-Nested/Nested'))
  $r = Invoke-Join $w8
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $w8.Mods 'Nested\Scripts\main.lua')) -and -not (Test-Path -LiteralPath (Join-Path $w8.Mods 'Other')) -and -not (Test-Path -LiteralPath (Join-Path $w8.Mods 'Nested\README.md'))) "only the chosen folder installs (got: $($r.Out.Trim()))"
  Check ((Text (Join-Path $w8.Mods 'Nested\enabled.txt.moonpool-off')) -eq 'Install-Nested\Nested\enabled.txt v1') 'its own enabled.txt is kept'
  $r = Invoke-Join $w8
  Check ($r.Code -eq 0 -and $r.Out -match 'mods up to date') "and it is current on the next run (got: $($r.Out.Trim()))"
  Write-Manifest $w8 @((Mod $w8 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '3.0'))
  $r = Invoke-Join $w8
  Write-Host 'the same archive installed to a new folder moves the mod'
  Write-Manifest $w8 @((Mod $w8 'Foo' 'Foo.zip' 'FooMoved' 'Foo' $true '3.0'))
  $r = Invoke-Join $w8
  Check ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $w8.Mods 'FooMoved\Scripts\main.lua')) -and -not (Test-Path -LiteralPath (Join-Path $w8.Mods 'Foo'))) "a changed folder is not current (got: $($r.Out.Trim()))"
  Write-Host 'an unreadable ledger starts over; a hostile archive is refused before unpacking'
  Set-Content -LiteralPath (Join-Path $w8.Root 'moonpool\owned.json') -Value '{ truncated'
  $r = Invoke-Join $w8
  Check ($r.Code -eq 0 -and $r.Out -match 'starting that record over') "a corrupt ledger does not block the join (got: $($r.Out.Trim()))"
  $w9 = New-World; $worlds += $w9
  New-RawZip (Join-Path $w9.Server 'Evil.zip') @('Scripts/main.lua', '../../evil.txt')
  Write-Manifest $w9 @((Mod $w9 'Evil' 'Evil.zip' 'Evil' ''))
  $r = Invoke-Join $w9
  Check ($r.Code -ne 0 -and $r.Out -match 'unsafe path in the archive' -and -not (Test-Path -LiteralPath $w9.Mods) -and $null -eq $r.Launched) "a climbing path is refused (got: $($r.Out.Trim()))"

  Write-Host 'an update whose archive breaks a limit is refused and the installed version stays'
  $wz = New-World; $worlds += $wz
  $src = Text $Script
  $maxEntries = [int]([regex]::Match($src, '(?m)^\$MaxArchiveEntries = (\d+)\s*$').Groups[1].Value)
  $maxBytes = [long]([regex]::Match($src, '(?m)^\$MaxUnpackedBytes = (\d+)GB\s*$').Groups[1].Value) * 1GB
  Write-Manifest $wz @((Mod $wz 'Foo' 'Foo.zip' 'Foo' 'Foo'))
  $r = Invoke-Join $wz
  Check ($r.Code -eq 0 -and (Text (Join-Path $wz.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v1') 'the mod to be updated is installed first'
  function Refused([string[]]$Names, [string]$Why, [hashtable]$Declare = @{}, [string]$Extra = '', [hashtable]$Bodies = @{}) {
    $before = Snapshot $wz.Game
    New-RawZip (Join-Path $wz.Server 'Foo.zip') $Names $Declare -Bodies $Bodies
    Write-Manifest $wz @((Mod $wz 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '2.0'))
    $r = Invoke-Join $wz -Extra $Extra
    $ok = $r.Code -ne 0 -and $r.Out -match $Why -and $null -eq $r.Launched -and (Snapshot $wz.Game) -eq $before
    if (-not $ok) { Write-Host "    exit $($r.Code): $($r.Out.Trim())" }
    return $ok
  }
  if (-not ($maxEntries -gt 0 -and $maxBytes -gt 0)) { throw 'the archive limits were not found in the launcher' }
  Check ((Refused @('Foo/Scripts/main.lua', 'Foo/Scripts/CON.lua') 'unsafe path in the archive: Foo/Scripts/CON\.lua') -and
         (Refused @('Foo/Scripts/main.lua', 'aux.txt') 'unsafe path in the archive: aux\.txt')) 'a Windows device name in the archive is refused'
  Check (Refused @('Foo/Scripts/main.lua', 'Foo/a.bin', 'Foo/b.bin') 'unpacks to more than' @{ 'Foo/a.bin' = 4294967294; 'Foo/b.bin' = ($maxBytes - 4294967294) }) 'an archive declaring one byte past the expansion limit is refused'
  Check (Refused (@('Foo/Scripts/main.lua') + @(1..$maxEntries | ForEach-Object { "Foo/f$_.txt" })) "holds $($maxEntries + 1) files") 'an archive one entry past the limit is refused'
  Check (Refused @('Foo/Scripts/main.lua', 'Foo/big.bin') 'unpacks to more than' @{ 'Foo/big.bin' = 1 } '-UnpackLimit 200000' @{ 'Foo/big.bin' = ('y' * 300000) }) 'an archive that declares 1 byte but holds more is stopped by the bytes really written'

  Write-Host 'an entry marked as a Unix symlink unpacks as a plain file holding the link text'
  New-RawZip (Join-Path $wz.Server 'Link.zip') @('Link/Scripts/main.lua', 'Link/Scripts/up.lua', 'Link/Scripts/win.lua') -Links @{ 'Link/Scripts/up.lua' = '../../../../../../outside.txt'; 'Link/Scripts/win.lua' = 'C:\Windows\win.ini' }
  Write-Manifest $wz @((Mod $wz 'Link' 'Link.zip' 'Link' 'Link'))
  $r = Invoke-Join $wz
  $placed = @('Link', 'Link\Scripts', 'Link\Scripts\up.lua', 'Link\Scripts\win.lua') | ForEach-Object { Get-Item -LiteralPath (Join-Path $wz.Mods $_) -Force -ErrorAction SilentlyContinue }
  Check ($r.Code -eq 0 -and @($placed).Count -eq 4 -and -not @($placed | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -and
         (Text (Join-Path $wz.Mods 'Link\Scripts\up.lua')) -eq '../../../../../../outside.txt') "no reparse point in the mod folder (got $($r.Code)): $($r.Out.Trim())"

  Write-Host 'a mod whose folder inside the archive climbs out of it is refused before anything is fetched'
  $wp = New-World; $worlds += $wp
  New-Zip (Join-Path $wp.Server 'Up.zip') @('Up\Scripts\main.lua')
  Write-Manifest $wp @((Mod $wp 'Up' 'Up.zip' 'Up' '../../Up'))
  $r = Invoke-Join $wp
  Check ($r.Code -ne 0 -and $r.Out -match 'unsafe folder inside its archive' -and -not $r.Launched) "the escape is refused (got: $($r.Out.Trim()))"

  Write-Host 'the loader is refused on a game build the server has not listed'
  $w4 = New-World; $worlds += $w4
  Write-Manifest $w4 @((Mod $w4 'Foo' 'Foo.zip' 'Foo' 'Foo')) 'server-a' $true @('0' * 64)
  $r = Invoke-Join $w4
  Check ($r.Code -ne 0 -and $r.Out -match 'not listed for this game build' -and -not (Test-Path -LiteralPath $w4.Mods)) 'plain line, nothing written'

  Write-Host 'wrong branch or build, a running game, and a corrupt archive each stop before any write'
  $w5 = New-World; $worlds += $w5
  Write-Manifest $w5 @((Mod $w5 'Foo' 'Foo.zip' 'Foo' 'Foo')) 'server-a' $true $null '9999' 'public'
  $r = Invoke-Join $w5
  Check ($r.Code -ne 0 -and $r.Out -match "server needs Steam branch 'public' build 9999" -and $null -eq $r.Launched) 'build gate names the branch and build'
  Write-Manifest $w5 @((Mod $w5 'Foo' 'Foo.zip' 'Foo' 'Foo'))
  $r = Invoke-Join $w5 -GameRunning
  Check ($r.Code -eq 2 -and $r.Out -match 'Subnautica 2 is running' -and -not (Test-Path -LiteralPath $w5.Mods)) 'running game: exit 2, nothing written'
  $m = Get-Content -LiteralPath $w5.Manifest -Raw | ConvertFrom-Json
  $m.mods[0].source.hashes[0].value = ('1' * 64)
  Set-Content -LiteralPath $w5.Manifest -Value ($m | ConvertTo-Json -Depth 10) -Encoding UTF8
  $r = Invoke-Join $w5
  Check ($r.Code -ne 0 -and $r.Out -match 'Foo\.zip failed its sha256 check' -and -not (Test-Path -LiteralPath $w5.Mods)) 'corrupt archive: nothing placed'

  Write-Host 'a server gives data: its key is checked, its claimed id is ignored, and code changes are asked about'
  $w6 = New-World; $worlds += $w6
  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
  $pub = $rsa.ExportParameters($false)
  $config = [ordered]@{
    manifest_url = 'https://elsewhere.example/mods.json'
    public_key = [ordered]@{ modulus = [Convert]::ToBase64String($pub.Modulus); exponent = [Convert]::ToBase64String($pub.Exponent) }
    server_name = 'Signed'; server_id = '..\..\..\evil'
  }
  Set-Content -LiteralPath (Join-Path $w6.Server 'moonpool.json') -Value ($config | ConvertTo-Json -Depth 5)
  function Sign-Manifest { [IO.File]::WriteAllBytes($w6.Manifest + '.sig', $rsa.SignData([IO.File]::ReadAllBytes($w6.Manifest), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))) }
  $at = "-Server '$(([Uri]$w6.Server).AbsoluteUri)'"
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo')) 'signed'; Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at -Answer '$false'
  Check ($r.Code -eq 3 -and $r.Out -match 'you declined' -and -not (Test-Path -LiteralPath (Join-Path $w6.Mods 'Foo'))) "declining installs nothing and does not start the game (got $($r.Code)): $($r.Out.Trim())"
  Check ($r.Asked -match 'Foo' -and $r.Asked -match 'UE4SS loader' -and $r.Asked -match 'Signed' -and -not $r.Launched) 'it names the server, each mod and the loader'
  Check ($r.Asked -match 'UE4SS loader from this server, native code') "the loader comes from this server and is native code (asked: $($r.Asked))"
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '1.0' 'ue4ss' $true 'https://mods.example/foo')) 'signed'; Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at -Answer '$false'
  Check ($r.Code -eq 3 -and $r.Asked -match 'Foo .* from mods\.example') "the question names the host a mod comes from: $($r.Asked)"
  $elsewhere = Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '1.0' 'ue4ss' $false 'https://mods.example/foo'
  $elsewhere.source.url = 'https://downloads.example/Foo.zip'
  Write-Manifest $w6 @($elsewhere) 'signed'; Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at -Answer '$false'
  Check ($r.Code -eq 3 -and $r.Asked -match 'Foo .* from downloads\.example') "that host is the one the file downloads from, not the page the manifest names: $($r.Asked)"
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo')) 'signed'; Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at
  Check ($r.Code -eq 0 -and $r.Asked -and (Test-Path -LiteralPath (Join-Path $w6.Mods 'Foo\Scripts\main.lua'))) "accepting installs (got $($r.Code)): $($r.Out.Trim())"
  $dirs = @(Get-ChildItem -LiteralPath (Join-Path $w6.Root 'moonpool') -Directory | Where-Object Name -match '^[0-9a-f]{16}$')
  Check ($dirs.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $w6.Root 'evil')) -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $w6.Root) 'evil'))) 'the folder comes from the key, not from what the server calls itself'
  $r = Invoke-Join $w6 -Extra $at
  Check ($r.Code -eq 0 -and -not $r.Asked -and $r.Launched) "the same set asks nothing and just joins (got: $($r.Out.Trim()))"
  $r = Invoke-Join $w6 -Extra "-Server $($dirs[0].Name)"
  Check ($r.Code -eq 0 -and -not $r.Asked -and $r.Launched) "the shortcut's form, by saved id, works (got: $($r.Out.Trim()))"
  New-Zip (Join-Path $w6.Server 'Foo.zip') @('Foo\Scripts\main.lua', 'Foo\Scripts\lib.lua') '9'
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '9')) 'signed'; Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at -Answer '$false'
  Check ($r.Code -eq 3 -and $r.Asked -match 'Foo' -and $r.Asked -notmatch 'UE4SS loader' -and (Text (Join-Path $w6.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v1') 'a changed mod asks again, about that change only, and stays as it was on no'
  $r = Invoke-Join $w6 -Extra $at
  Check ($r.Code -eq 0 -and (Text (Join-Path $w6.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v9') 'and updates on yes'
  New-Zip (Join-Path $w6.Server 'Foo.zip') @('Foo\Scripts\main.lua', 'Bad\Scripts\main.lua') '9b'
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '9')) 'signed'; Sign-Manifest
  [void](Invoke-Join $w6 -Extra $at)
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Bad' $true '9')) 'signed'; Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at -Answer '$false'
  Check ($r.Code -eq 3 -and $r.Asked -match 'Foo' -and (Text (Join-Path $w6.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v9b') 'the same archive pointed at another folder inside it asks again'
  $evil = Mod $w6 'Page' 'Foo.zip' 'Page' 'Foo' $true '1' 'ue4ss' $true 'powershell.exe'
  Write-Manifest $w6 @($evil) 'signed'; Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at
  Check ($r.Code -ne 0 -and -not $r.Page -and $r.Out -match 'not an https address') "a page that is not https is never opened (got: $($r.Out.Trim()))"
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '9')) 'signed'; Sign-Manifest
  [IO.File]::WriteAllBytes($w6.Manifest + '.sig', (New-Object byte[] 384))
  New-Zip (Join-Path $w6.Server 'Foo.zip') @('Foo\Scripts\main.lua', 'Foo\Scripts\lib.lua') '10'
  Write-Manifest $w6 @((Mod $w6 'Foo' 'Foo.zip' 'Foo' 'Foo' $true '10')) 'signed'
  $r = Invoke-Join $w6 -Extra $at
  Check ($r.Code -ne 0 -and $r.Out -match 'signature is invalid' -and (Text (Join-Path $w6.Mods 'Foo\Scripts\main.lua')) -eq 'Foo\Scripts\main.lua v9b') 'bad signature: nothing changed'
  $oldKey = $config.public_key.modulus
  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
  $config.public_key.modulus = [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus)
  $config.public_key.exponent = [Convert]::ToBase64String($rsa.ExportParameters($false).Exponent)
  Set-Content -LiteralPath (Join-Path $w6.Server 'moonpool.json') -Value ($config | ConvertTo-Json -Depth 5)
  Sign-Manifest
  $r = Invoke-Join $w6 -Extra $at -Answer '$false'
  Check ($r.Code -eq 3 -and $r.Asked -match 'different server key') "a new key at the same address is a new server, with a warning (got: $($r.Out.Trim()))"

  Write-Host 'a mod with a DLL is named as native code when consent is asked'
  $wn = New-World; $worlds += $wn
  New-Zip (Join-Path $wn.Server 'Prox.zip') @('Prox\Scripts\main.lua', 'Prox\dlls\main.dll')
  Write-Manifest $wn @((Mod $wn 'Prox' 'Prox.zip' 'Prox' 'Prox' -Native $true))
  $r = Invoke-Join $wn
  Check ($r.Code -eq 0 -and $r.Asked -match 'Prox 1\.0 from .*, native code' -and $r.Asked -match "Windows account's rights") "the consent text says native code and the rights it runs with (asked: $($r.Asked.Trim()))"

  Write-Host 'an archive Defender could not scan is asked about, once, and a no stops it'
  $wu = New-World; $worlds += $wu
  New-Zip (Join-Path $wu.Server 'Quiet.zip') @('Quiet\Scripts\main.lua')
  Write-Manifest $wu @((Mod $wu 'Quiet' 'Quiet.zip' 'Quiet' 'Quiet'))
  $r = Invoke-Join $wu -Scan "'unscanned'" -Answer "(`$q -notmatch 'could not be scanned')"
  Check ($r.Code -eq 3 -and $r.Out -match 'not scanned and you declined' -and -not (Test-Path -LiteralPath (Join-Path $wu.Mods 'Quiet')) -and -not $r.Launched) "a no on an unscanned archive places nothing (got: $($r.Out.Trim()))"
  $r = Invoke-Join $wu -Scan "'unscanned'"
  Check ($r.Code -eq 0 -and $r.Asked -match 'could not be scanned' -and (Test-Path -LiteralPath (Join-Path $wu.Mods 'Quiet'))) "a yes installs it and the question named the scan (asked: $($r.Asked.Trim()))"
  $r = Invoke-Join $wu -Scan "'unscanned'" -Answer "(`$q -notmatch 'could not be scanned')"
  Check ($r.Code -eq 0 -and $r.Asked -notmatch 'could not be scanned') "the same archive is not asked about twice (asked: $($r.Asked.Trim()))"

  Write-Host 'an archive listed with sha1 first and sha256 second is named by its sha256'
  $wh = New-World; $worlds += $wh
  New-Zip (Join-Path $wh.Server 'Hashed.zip') @('Hashed\Scripts\main.lua')
  Write-Manifest $wh @((Mod $wh 'Hashed' 'Hashed.zip' 'Hashed' 'Hashed' -Algorithms @('sha1', 'sha256')))
  $r = Invoke-Join $wh
  $ledger = Get-Content -LiteralPath (Join-Path $wh.Root 'moonpool\owned.json') -Raw | ConvertFrom-Json
  $record = @($ledger.mods.PSObject.Properties | Where-Object { $_.Name -like '*/Hashed' })[0].Value
  Check ($r.Code -eq 0 -and $record.archive -eq (Sha (Join-Path $wh.Server 'Hashed.zip'))) "the ledger records the sha256 (got: $($record.archive))"

  Write-Host 'an archive Windows Defender flags is not unpacked'
  $w11 = New-World; $worlds += $w11
  New-Zip (Join-Path $w11.Server 'Flagged.zip') @('Flagged\Scripts\main.lua')
  Write-Manifest $w11 @((Mod $w11 'Flagged' 'Flagged.zip' 'Flagged' 'Flagged'))
  $r = Invoke-Join $w11
  Check ($r.Code -ne 0 -and $r.Out -match 'Defender flagged' -and -not (Test-Path -LiteralPath (Join-Path $w11.Mods 'Flagged')) -and -not $r.Launched) "nothing is placed and the game does not start (got: $($r.Out.Trim()))"

  Write-Host 'uninstall takes off what Moonpool placed and set up, keeps what the player owns or changed, and is safe twice'
  $wx = New-World; $worlds += $wx
  $env:MOONPOOL_SHORTCUTS = Join-Path $wx.Root 'shell'
  $kit = Join-Path $wx.Root 'moonpool'
  $handlerKey = 'HKCU:\Software\moonpool-tests\moonpool'
  Set-Content -LiteralPath (Join-Path $wx.Win64 'notes.txt') -Value 'mine' -NoNewline
  New-Item -ItemType Directory -Path (Join-Path $wx.Mods 'MyMod\Scripts') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $wx.Mods 'MyMod\Scripts\main.lua') -Value 'my mod' -NoNewline
  New-Item -ItemType Directory -Path (Join-Path $env:MOONPOOL_SHORTCUTS 'Desktop') -Force | Out-Null
  $mine = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $env:MOONPOOL_SHORTCUTS 'Desktop\Subnautica 2 (my own).lnk'))
  $mine.TargetPath = "$env:SystemRoot\notepad.exe"; $mine.Save()
  $pristine = Snapshot $wx.Game
  $xrsa = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
  $xpub = $xrsa.ExportParameters($false)
  $xcfg = [ordered]@{ public_key = [ordered]@{ modulus = [Convert]::ToBase64String($xpub.Modulus); exponent = [Convert]::ToBase64String($xpub.Exponent) }; server_name = 'Gone' }
  Set-Content -LiteralPath (Join-Path $wx.Server 'moonpool.json') -Value ($xcfg | ConvertTo-Json -Depth 5)
  Write-Manifest $wx @((Mod $wx 'Foo' 'Foo.zip' 'Foo' 'Foo'), (Mod $wx 'Baz' 'Baz.zip' 'Baz' 'Baz' $true '3' 'pak'))
  [IO.File]::WriteAllBytes($wx.Manifest + '.sig', $xrsa.SignData([IO.File]::ReadAllBytes($wx.Manifest), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')))
  $r = Invoke-Join $wx -Extra "-Server '$(([Uri]$wx.Server).AbsoluteUri)'" -Shortcuts
  $links = @(Get-ChildItem -LiteralPath $env:MOONPOOL_SHORTCUTS -Filter '*.lnk' -Recurse)
  Check ($r.Code -eq 0 -and (All-Off $wx) -and (Test-Path -LiteralPath $handlerKey) -and $links.Count -eq 4 -and (Test-Path -LiteralPath (Join-Path $kit 'moonpool.ps1'))) "set up: joined, handler, three shortcuts of its own and the installed copy (got $($r.Code), $($links.Count) links): $($r.Out.Trim())"
  Set-Content -LiteralPath (Join-Path $wx.Mods 'Foo\Scripts\lib.lua') -Value 'my edit' -NoNewline
  $r = Invoke-Join $wx -GameRunning -Extra '-Uninstall'
  Check ($r.Code -eq 2 -and $r.Out -match 'Subnautica 2 is running' -and (All-Off $wx) -and (Test-Path -LiteralPath $handlerKey) -and (Test-Path -LiteralPath (Join-Path $kit 'owned.json'))) "refused while the game runs, nothing changed (got $($r.Code)): $($r.Out.Trim())"
  # From the installed copy, with its folder as the working folder of the process above it, as a shortcut runs it.
  $oldScript = $Script; $Script = Join-Path $kit 'moonpool.ps1'; $cwd = [Environment]::CurrentDirectory
  [IO.Directory]::SetCurrentDirectory($kit)
  $wrote = Join-Path $wx.Mods 'Foo\state.dat'; Set-Content -LiteralPath $wrote -Value 'the mod wrote this' -NoNewline
  try { $r = Invoke-Join $wx -Extra '-Uninstall' } finally { [IO.Directory]::SetCurrentDirectory($cwd); $Script = $oldScript }
  Check ($r.Out -match ('(?m)^Still there, holding files Moonpool never placed[^:]*: ' + [regex]::Escape((Join-Path $wx.Mods 'Foo').ToLowerInvariant()) + '\s*$') -and (Test-Path -LiteralPath $wrote)) "the one folder a mod wrote into stays and is the only one named (got: $($r.Out.Trim())"
  Remove-Item -LiteralPath $wrote
  $edited = Join-Path $wx.Mods 'Foo\Scripts\lib.lua'
  Check ($r.Code -eq 0 -and $r.Out -match 'uninstalled' -and $r.Out -match [regex]::Escape($edited.ToLowerInvariant()) -and (Text $edited) -eq 'my edit') "the changed file is kept and named (got $($r.Code)): $($r.Out.Trim())"
  Remove-Item -LiteralPath $edited
  Check ((Snapshot $wx.Game) -eq $pristine -and -not (Test-Path -LiteralPath $wx.Paks) -and -not (Test-Path -LiteralPath (Join-Path $wx.Mods 'Foo\enabled.txt')) -and (Test-Path -LiteralPath (Join-Path $wx.Mods 'MyMod'))) 'every other file is as it was before Moonpool, live or parked, and the folders it made are gone'
  $links = @(Get-ChildItem -LiteralPath $env:MOONPOOL_SHORTCUTS -Filter '*.lnk' -Recurse)
  Check (-not (Test-Path -LiteralPath $handlerKey) -and $links.Count -eq 1 -and $links[0].Name -eq 'Subnautica 2 (my own).lnk') "the handler and its shortcuts are gone, the player's own shortcut stays (left: $(@($links | ForEach-Object Name) -join ', '))"
  for ($i = 0; $i -lt 40 -and (Test-Path -LiteralPath $kit); $i++) { Start-Sleep -Milliseconds 250 }
  Check (-not (Test-Path -LiteralPath $kit)) "its folder is gone, launcher included, once the run's console lets it go"
  $again = Snapshot $wx.Game
  New-Item -Path "$handlerKey\shell\open\command" -Force | Out-Null
  Set-ItemProperty -LiteralPath "$handlerKey\shell\open\command" -Name '(default)' -Value 'another-program.exe "%1"'
  $r = Invoke-Join $wx -Extra '-Uninstall'
  Check ($r.Code -eq 0 -and $r.Out -match 'Removed 0 game file' -and $r.Out -notmatch 'link handler' -and (Snapshot $wx.Game) -eq $again -and -not (Test-Path -LiteralPath $kit)) "a second uninstall is harmless (got $($r.Code)): $($r.Out.Trim())"
  Check (Test-Path -LiteralPath $handlerKey) 'a moonpool: handler that opens another program is not removed'
  Remove-Item Env:MOONPOOL_SHORTCUTS

  Write-Host 'a join link: only a safe address, and nothing else alongside it'
  $w9 = New-World; $worlds += $w9
  function Link-Run([string]$Args1) {
    $keep = $env:LOCALAPPDATA; $env:LOCALAPPDATA = $w9.Root
    try { $o = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$Script' $Args1; exit `$LASTEXITCODE" 2>&1 | Out-String; return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
    finally { $env:LOCALAPPDATA = $keep }
  }
  $r = Link-Run '-Install'
  $handler = (Get-ItemProperty -LiteralPath 'HKCU:\Software\moonpool-tests\moonpool\shell\open\command').'(default)'
  Check ($handler -match 'conhost\.exe" --headless "[^"]+powershell\.exe" -NoProfile' -and $handler -match '-Link "%1"$') "the link runs the launcher with no console window (got: $handler)"
  $r = Link-Run "-Link 'moonpool:http://8.8.8.8:8081'"
  Check ($r.Code -ne 0 -and $r.Out -match 'not a server address') "plain http to the internet is refused (got: $($r.Out.Trim()))"
  $r = Link-Run "-Link 'moonpool:https://x.example/'' -Evil'"
  Check ($r.Code -ne 0 -and $r.Out -match 'not a server address') "a link with script characters is refused (got: $($r.Out.Trim()))"
  $r = Link-Run "-Link 'moonpool:https://x.example' -Adopt"
  Check ($r.Code -ne 0 -and $r.Out -match 'comes alone') "a link carrying another option is refused (got: $($r.Out.Trim()))"
  $r = Link-Run "-Link 'moonpool:https://x.example' -Uninstall"
  Check ($r.Code -ne 0 -and $r.Out -match 'comes alone' -and (Test-Path -LiteralPath 'HKCU:\Software\moonpool-tests\moonpool')) "a link cannot uninstall (got: $($r.Out.Trim()))"

  $r = Link-Run "-Server 'https://x.invalid'"
  Check ($r.Code -ne 0) 'an unreachable server stops the run'

  Write-Host 'the launcher updates only from its own release address, and only as the installed copy'
  $w10 = New-World; $worlds += $w10
  New-Item -ItemType Directory -Path (Join-Path $w10.Root 'moonpool') | Out-Null
  $installed = Join-Path $w10.Root 'moonpool\moonpool.ps1'
  # The installed copy trusts a key made here: the release key's private half is not on this machine.
  $releaseRsa = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
  $otherRsa = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
  $releasePub = $releaseRsa.ExportParameters($false)
  $keyLine = "`$ReleaseKey = @{ modulus = '$([Convert]::ToBase64String($releasePub.Modulus))'; exponent = '$([Convert]::ToBase64String($releasePub.Exponent))' }"
  $keyed = (Text $Script) -replace '(?m)^\$ReleaseKey = @\{[^\r\n]*', $keyLine
  Set-Content -LiteralPath $installed -Value $keyed -NoNewline
  $next = Join-Path $w10.Root 'next.ps1'
  function Write-Release([int]$Build, $Signer = $releaseRsa) {
    Set-Content -LiteralPath $next -Value ($keyed -replace '(?m)^\$LauncherBuild = 0', "`$LauncherBuild = $Build") -NoNewline
    [IO.File]::WriteAllBytes("$next.sig", $Signer.SignData([IO.File]::ReadAllBytes($next), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')))
  }
  Write-Manifest $w10 @() 'none' $false
  $env:SN2_JOIN_UPDATE_URL = ([Uri]$next).AbsoluteUri
  $oldScript = $Script; $Script = $installed
  Write-Release 5
  $r = Invoke-Join $w10
  Check ($r.Launched -eq 'self-update' -and (Sha $installed) -eq (Sha $next)) "a validly signed newer release replaces it and restarts (got $($r.Launched)): $($r.Out.Trim())"
  $kept = Sha $installed
  $r = Invoke-Join $w10
  Check ($r.Code -eq 0 -and $r.Launched -ne 'self-update') "the same release does not (got $($r.Launched))"
  Write-Release 4
  $r = Invoke-Join $w10
  Check ($r.Launched -ne 'self-update' -and (Sha $installed) -eq $kept -and (Text $installed) -match '(?m)^\$LauncherBuild = 5') "a validly signed older release is never installed (got $($r.Launched))"
  Write-Release 6
  Add-Content -LiteralPath $next -Value '# changed after signing'
  $r = Invoke-Join $w10
  Check ($r.Code -eq 0 -and $r.Launched -and $r.Launched -ne 'self-update' -and (Sha $installed) -eq $kept) "a release changed after signing is refused (got $($r.Launched))"
  Write-Release 7
  Remove-Item -LiteralPath "$next.sig"
  $r = Invoke-Join $w10
  Check ($r.Code -eq 0 -and $r.Launched -and $r.Launched -ne 'self-update' -and (Sha $installed) -eq $kept) "a release with no signature is refused (got $($r.Launched))"
  Write-Release 8 $otherRsa
  $r = Invoke-Join $w10
  Check ($r.Code -eq 0 -and $r.Launched -and $r.Launched -ne 'self-update' -and (Sha $installed) -eq $kept) "a release signed by another key is refused (got $($r.Launched))"
  Remove-Item -LiteralPath $next, "$next.sig"
  $r = Invoke-Join $w10
  Check ($r.Code -eq 0 -and $r.Launched -and $r.Launched -ne 'self-update' -and (Sha $installed) -eq $kept) "an unreachable release keeps the installed copy (got: $($r.Out.Trim()))"
  Remove-Item Env:SN2_JOIN_UPDATE_URL
  $Script = $oldScript
} finally {
  foreach ($x in $worlds) { Remove-Item -LiteralPath $x.Root -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item -Path 'HKCU:\Software\moonpool-tests' -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item Env:MOONPOOL_CLASSES_ROOT -ErrorAction SilentlyContinue
}

Write-Host "$passes passed, $failures failed"
if ($failures -gt 0) { exit 1 }
exit 0
