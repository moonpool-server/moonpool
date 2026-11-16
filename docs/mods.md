# Mods

Two kinds: mods players install through the launcher ([Player mods](#player-mods)), and mods the server itself runs ([Server mods](#server-mods)). How players' launchers trust a server and its mods is in [SECURITY.md](../SECURITY.md).

## Player mods

```sh
cp plugins.example.yaml plugins.yaml   # edit it with any editor
bin/moonpool mods publish plugins.yaml
bin/moonpool mods list
```

- Each entry needs a download link: a GitHub release file, a CurseForge file page or a Nexus file page.
- CurseForge needs `CURSEFORGE_API_KEY` in `.env` (free at console.curseforge.com) and an author who allows distribution; otherwise players download it from its page.
- Nexus files, and CurseForge files their author keeps on CurseForge: run `bin/moonpool mods pin "<name>" <file.zip>` once. The server never fetches or serves these; players download them and the launcher checks they match.
- `.pak` mods need `kind: pak`. Optional mods are ticked unless `default: false`.
- The join page shows each mod's `summary`, or its own description from GitHub or CurseForge, with stars or downloads, last update and author. These are read at most every `MOD_STATS_MAX_AGE` seconds (21600, six hours). CurseForge needs the key; `GITHUB_TOKEN` in `.env` raises GitHub's limit of 60 reads an hour.

## On the player's PC

Players install the launcher once, from the join page. Then:

- Mandatory mods are ticked and locked. Choices are remembered per server and asked again, with changes marked, when a mod is added or changes.
- Mods are on only while the game the launcher started is running. If the launcher is killed mid-game, they stay on until its next run or the "Subnautica 2 (without Moonpool mods)" shortcut.
- The player's own mods are left alone, except a `UE4SS_Signatures` folder the server didn't send, which is moved aside while Moonpool's mods are on.
- A mod loader installed another way is replaced only after asking, with a copy in `%LOCALAPPDATA%\Moonpool-replaced`.
- Two settings go into the game's `Engine.ini` for the session and come out when the game closes; a value the player set is kept. `r.ShaderPipelineCache.BackgroundBatchSize=100` shortens the shader wait before joining (about 3 minutes to 7 seconds on one PC), and `ConfiguredInternetSpeed`/`ConfiguredLanSpeed=300000` speed up loading.
- Steam only: Xbox and Game Pass players join without mods.

Player logs: the "Subnautica 2 (collect logs for the host)" Start menu shortcut, or `moonpool.ps1 -CollectLogs`, puts one zip on the Desktop. It holds the launcher's log, the game's and UE4SS's logs, the record of placed files and crash folder names. Windows user and PC names are removed, crash dumps left out and nothing uploaded. It still names the server, its players and Steam IDs, so send it only to the host.

Uninstall: close Subnautica 2, then in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Moonpool\moonpool.ps1" -Uninstall
```

- Removes every game file it placed that is unchanged, folders left empty, its `moonpool:` link handler, shortcuts and own folder. Files changed since stay and are named.
- Copies in `%LOCALAPPDATA%\Moonpool-replaced` stay and aren't put back. `-Adopt` replaces files without asking or copying.
- Steam's Verify integrity of game files restores the game's own files.

## Server mods

- **Pak mods**: `.pak`, `.ucas` and `.utoc` files in `paks-local/` in the data volume. Each launch copies them into the game's `Content/Paks/~mods` and removes ones you've taken out. Mods that change game rules (storage sizes, vehicle stats) usually need to be on the server as well as in `plugins.yaml`; the host decides those in co-op.
- **UE4SS mods**: `ue4ss-local/Mods/<name>/` in the data volume, with an empty `enabled.txt` beside `Scripts`; recreate the host. To remove one, delete it there and from `ue4ss/Mods` in the game folder. Most act on the local player, so they do nothing on a server; list those in `plugins.yaml` instead.

Server mods run with the server's rights and Steam session. Only use ones you trust.

## Players' loader on experimental builds

On some builds the mod loader needs layout files its release lacks, or the game crashes about ten seconds after start. Put a `MemberVariableLayout.ini`, `VTableLayout.ini` and `UE4SS-settings.ini` that work on a player's PC for the current build in `ue4ss-client/` in the data volume. The server's own go in `ue4ss-local/` ([Updates](operating.md#updates)).

- The settings file matters: on experimental build 26496980 the release's default crashes the game. The working file sets `MajorVersion = 5`, `MinorVersion = 6`, `DebugBuild = false`.
- The pinned loader is served with those files added, under its own name and hash. Anyone who can reach the join page can fetch it.
- A player is asked before their own layout files are replaced.
