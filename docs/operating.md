# Running Moonpool

Settings: `.env.example`. Commands: `bin/moonpool help`.

## Size

| Players | Cores | Memory | SSD | Upload | Source |
|---|---|---|---|---|---|
| 2 | 2.3 | 6 GB | | | measured on a test host |
| 4 | 4 | 8 GB | 40 GB | 10 Mbit | scaled from 2 players |
| 8 | 6 | 12 GB | 60 GB | 25 Mbit | a guess |

`metrics.csv` in the data volume shows what your host uses.

Empty server, friends preset:

- After `IDLE_SLOW_MINUTES` (2) with nobody in, the frame cap drops to `IDLE_MAX_FPS` (10). `SERVER_MAX_FPS` returns when a login shows in the game log, or at the next roster check. A command that can't be sent yet is retried at the next check.
- On a test host an empty game used about 3.3 cores at full rate and two-thirds of a core at 10 fps. Joins took as long as at full rate.
- Lower caps save little (game process: 60% of a core at 10, 51% at 5, 32% at 1) and are untested with joins.
- `IDLE_MAX_FPS=0` turns it off. With `PRESET=stock` it's off unless set.
- `IDLE_FREEZE_MINUTES` freezes the clock. `IDLE_STOP_HOURS` stops the game, freeing CPU and memory; nobody can join until it starts again.

Joining players get world data at up to `NET_MAX_CLIENT_RATE` bytes a second each: 300000 with the friends preset, the game's 100000 with `PRESET=stock` or `NET_MAX_CLIENT_RATE=100000`. On a test host a join sent about 1.4 MB (peak about 160 KiB/s) and loaded in 15 s instead of 31 s.

## Signing in

- Use the hosting account with Steam Guard on, and pick Remember me.
- To paste, put the text in the noVNC side panel's clipboard, then press Ctrl+V in Steam.
- You type the password into Steam. Moonpool doesn't ask for it or keep it, and it isn't in `.env`.

The viewer controls the signed-in Steam. Keep it off the internet.

- It always has a password, made at first start unless `VNC_PASSWORD` is set. `bin/moonpool diag viewer` shows it.
- VNC uses only the first 8 characters, and its handshake isn't encrypted.
- Inside Docker it listens on every interface; the password keeps other containers out.
- From elsewhere use an SSH tunnel or Tailscale, even with `VIEWER_BIND=0.0.0.0` on your LAN.

The sign-in stays in the data volume; anything in the container can use it. Moonpool reads the Steam client's web session from its cookie store there to find the lobby for the join link and to accept friend requests (`AUTO_ACCEPT_FRIENDS=0` turns accepting off). Use a dedicated account and keep the volume private.

Lost the machine? Deauthorize devices in Steam and change the password. `docker compose down -v` deletes the world and its saves for good.

## Joining

The game needs no forwarded port.

1. `bin/moonpool players invite <steamid64 or profile link>`.
2. The player sends the hosting account a friend request.
3. Accept it in the viewer, or set `AUTO_ACCEPT_FRIENDS=1` and Moonpool accepts invited players within a minute.
4. They press Join Game or use the join page.

- `ALLOWLIST_ONLY=false` lets in anyone who asks.
- With `AUTO_ACCEPT_FRIENDS=0` Moonpool still reads waiting requests once a minute, accepting or refusing none. The Discord card and `bin/moonpool status` show how many it would let in (never a banned player); `status` names up to five with `SHOW_PLAYER_NAMES=true`.
- Existing friends of the account can join until removed in the viewer or with `bin/moonpool ban add`.
- Everyone needs the same `STEAM_BRANCH` and game build.

| Command | Effect |
|---|---|
| `players kick` | removes a player for now |
| `ban add <name>` | removes a matching player whenever they join |
| `ban add <steamid64>` | also unfriends them, only with `AUTO_ACCEPT_FRIENDS=1`; otherwise remove them in the viewer or they can still join |

## Public address

Players reach the join page and mods on port 8081. Pick one:

- **Quick tunnel**: `TUNNEL=quick` and `COMPOSE_PROFILES=tunnel` in `.env`. Free. The address is random and changes when the tunnel restarts (a reboot, say). Send friends to the Discord card or `bin/moonpool status`, which show the current one.
- **Stable, no domain**: [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel). Run `tailscale funnel --bg http://127.0.0.1:8081` on the host, then set `SN2_PUBLIC_URL=https://<machine>.<tailnet>.ts.net`, `TUNNEL=off`, `MODS_BIND=127.0.0.1`. Free, in beta, with unstated bandwidth limits; test a mod download.
- **Your own domain** on Cloudflare (tunnel free on the free plan; you pay for the domain):
  1. A domain bought elsewhere: add it to Cloudflare's free plan and set its name servers to the two Cloudflare gives.
  2. Dashboard, Networking, Tunnels: create a tunnel, choose Docker, copy the token from the command shown.
  3. Add a Published application route: your hostname, service `http://sn2:8081`.
  4. In `.env`: `TUNNEL=token`, `COMPOSE_PROFILES=tunnel-token`, `TUNNEL_TOKEN=<token>`, `SN2_PUBLIC_URL=https://<hostname>`. Recreate the host.

  Anyone with the token can run your tunnel. Keep it out of chat, screenshots and the repo.
- **Your own network only**: `http://<this machine's address>:8081/join`.

Never forward the viewer's port 8080. Don't put 8081 on the internet as plain http.

## Xbox and Game Pass players

Experimental. They can't be invited through Steam. They add the hosting account by its in-game friend code and join from the game's friends list.

`bin/moonpool diag friend-code` opens the game's Friends screen (the code exists only while it's open), reads the code off the screen and closes it. Run it while nobody is on, or with `--force`. Each run makes a new code. The last one survives restarts and shows on the Discord card.

## Mods

```sh
cp plugins.example.yaml plugins.yaml   # edit it with any editor
bin/moonpool mods publish plugins.yaml
bin/moonpool mods list
```

- Each entry needs a download link: a GitHub release file, a CurseForge file page or a Nexus file page.
- CurseForge needs `CURSEFORGE_API_KEY` in `.env` (free at console.curseforge.com) and an author who allows distribution; otherwise players download it from its page.
- Nexus files, and CurseForge files kept on CurseForge by their author: run `bin/moonpool mods pin "<name>" <file.zip>` once (for CurseForge, the file it lists). The server never fetches or serves these; players download them and the launcher checks the match.
- `.pak` mods need `kind: pak`. Optional mods are ticked unless `default: false`.
- The join page shows `summary`, or the project's own description from GitHub or CurseForge, plus stars or downloads, last update and author. These are read at most every six hours (`MOD_STATS_MAX_AGE` seconds); the last numbers stay if a read fails. CurseForge needs the key. GitHub allows 60 unauthenticated reads an hour; `GITHUB_TOKEN` in `.env` is used if set.

In the launcher, mandatory mods are ticked and locked. Choices are remembered per server and asked again, with changes marked, when a mod is added or changes. Mods are on only until Subnautica 2 closes; if the launcher is killed mid-game, its next run or the Subnautica 2 (without Moonpool mods) shortcut turns them off. Steam only: Xbox and Game Pass players join without mods.

Player logs: the Subnautica 2 (collect logs for the host) Start menu shortcut, or `moonpool.ps1 -CollectLogs`, puts one zip on the Desktop. The launcher's error window points to it.

- Holds the launcher's log, `Subnautica2.log`, UE4SS's log and settings, the record of placed files, crash folder names and versions.
- Windows user and PC names are removed. Crash dumps are left out (they hold memory). Nothing is uploaded.
- Not anonymous: the logs name the server, its players and Steam IDs. Send it only to the host.

Uninstall: close Subnautica 2, then in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Moonpool\moonpool.ps1" -Uninstall
```

- Removes every game file it placed that is unchanged (on or off), folders left empty, its `moonpool:` link handler, shortcuts and own folder. Files changed since stay and are named.
- Files it didn't place were replaced only after asking, with copies in `%LOCALAPPDATA%\Moonpool-replaced`. Uninstall leaves those and doesn't restore them. `-Adopt` replaces without asking or copying.
- Steam's Verify integrity of game files restores the game's own files.

## In game admin

Admins by Epic ID: `ADMINS` in `.env` (read at start), or `control/admins.txt` in the data volume (one per line, re-read while running; text after a space is a note, `#` starts a comment). The UE4SS log prints `player NAME eos=...` on join. Names and Steam IDs don't count; a client can claim those.

Orders need nothing installed: rename any PDA signal to a command. The host writes the answer into the signal's name (about 40 characters show), green for done, red for refused, and as a notification on the sender's screen. A signal renamed by a non-admin is ignored without a reply.

```
!help                 the list
!kick NAME            remove a player
!time 12:00           set the clock
!weather DA_Storm     set the weather
!slots 8              change the player cap
!ping                 where everyone is, for admins; your own spot for anyone
!cmd LINE             one of the game's console commands, run on the host as you
!mp LINE              the admin console
```

`!cmd` and `!mp` need `player` in `enabled_commands` ([Console commands](#console-commands)). `!mp` takes any console line plus shortcuts and name lookups:

```
!mp g cop 10              Give the only item whose name starts with cop, 10 of it
!mp g 10 titanium ingot   the name's words and the number in any order, no quotes needed
!mp g tit                 an unclear name asks: tit? 1 Titanium  2 Titanium Ingot
!mp 2                     ...and a bare number answers it
!mp h                     a shortcut with several lines: heal, then oxygen, food and water to 100
!mp @john h               heal the player whose name matches john; @all and @host work too
!mp f titan               find items, players and tags by name, with their ids
!mp l items cop           list one kind, filtered
!mp l commands            the game's console commands, once the host is in the world
!mp c                     which cheat tags named in console.json are on; also cheats in status.json
!mp w                     who is on, with their Epic ID and ping
!mp SomeConsoleCommand 3  any other line goes to the game as typed
!mp .                     the last line again
```

Words, shortcuts and replies come from `console.json` (shipped: `mod/SN2SlotFreeHost/console.json`). Put one with only your changed keys in the data volume and recreate the host. Objects such as `commands` merge with the shipped ones; lists such as `deny` replace them.

```json
{
  "commands": {
    "full": { "aliases": ["full"], "lines": ["HealMe", "attr oxygen 100"] }
  }
}
```

- `commands` maps a word to console lines. Arguments are looked up by kind; see `give` in the shipped file.
- `on_ambiguous: first` takes the best match without asking.
- `deny` blocks commands that crash or wipe the world. `"deny": []` in your own file turns that off.
- `line_gap_ms` (1000) spaces the lines of one order; each can stall the server a second or so.

`off` (or `normal`) runs `DayOnly 0` and `RemoveGlobalTag` for each tag in `tags`. On this build every cheat, god mode and invisibility included, is a world tag, so `off` clears it for everyone. It can't undo:

- `FastSwim`: only the admin's PC, not a tag. Run it again.
- `QuickNav`'s fog and speed on the admin's PC: the game's `NormalNav`.

`god` and `fastbuild` toggle and ignore a number (`FastBuild 0` turns it on). The game's `RemoveTag` and `AddTag` act on the player who runs them and leave the world's cheat on; `tag+`, `tag-` and `off` use the `Global` commands.

Kits are the game's macros: text files in `Content/Macros` on each admin's PC, one console line per row, listed by the cheat panel's Macro button or run with `RunMacro <name>`. The host checks each line. As run from the panel on this build:

| Macro | What it does | Undo |
|---|---|---|
| Base Pack, Equipment Pack, Starting Items | gives or equips items (Starting Items' `OxygenTankSmall` is not found on this build) | nothing to undo |
| QuickNav | no fog, speed 10, fast swim on this PC; day, frozen at noon, for the world | the game's `NormalNav` |
| Superman | `god`, `fastbuild 1`, `unlockall`, `invisible` (all toggles: a cheat already on turns off), fast swim | `off`; `FastSwim` again for swimming |
| SculptDebug | habitat builder, then the toggles `god`, `freebuild`, `unlimitedpower` | `off` |
| SculptDebugNoSupports | SculptDebug, then `BaseToggleSupportCheck` | `off`, and `BaseToggleSupportCheck` once more: the game keeps no tag for it and says nothing, so the host cannot tell whether it is on |
| damagedebug | four `giveability` lines | nothing: the game answers "Could not find blueprint" for each on this build |

Rate limits (each console command can stall the server a second or two):

| Queue | Rate | Waiting |
|---|---|---|
| Cheat lines from an admin's game (typed, picked, macro lines) | one per `cheat_gap_s` (1 s, in `console.json`), at most one per mod poll (2 s) | `cheat_per_sender` (12) per admin |
| Signal orders and console lines | one per 3 s per admin; one per `admin_gap_s` (10 s, the mod's `config.json`) in all | 3 per admin, 20 in all, then Busy |

### The game's own cheat panel

The game sends a cheat line from any client to the host (`SN2PlayerController:ServerCheat`) and runs it without checking the sender. The game has no way to open its cheat panel, but any client mod that shows it can send lines. The host mod gates them:

- It takes the cheat manager off the sender's controller for the call, so the game's code runs nothing.
- From someone in `ADMINS`, the host mod runs the line, unless `deny` names it, and only with `player` in `enabled_commands`. From anyone else it is dropped and logged as `cheat gate: dropped`.
- `ExecuteForAll` asks the host to relay a message on a cheat channel to every player's game, which runs it as that player. The host relays it only from an admin and only if `deny` doesn't name the command; otherwise it moves it to a dead channel and logs `cheat gate: dropped … on GameplayMessage.Cheat…` (`cheat_channel`, `blocked_channel` in `console.json`).
- If the cheat manager can't be taken off, the line runs and can't be called back. The log says `cheat gate: COULD NOT STOP` and a non-admin sender is removed (`on_gate_failure`; `log` only logs).
- `deny` reads the first word, so it lists `ExecuteForAll` and `RunMacro`. A macro picked in the panel still works: its lines arrive one at a time and each is checked.

A line starting with `signal_word` (`mp`) is a console line: `mp g tit 10` equals `!mp g tit 10` in a signal. The answer shows as a notification for `reply_seconds` (8). A line for a player whose character isn't in the world yet is skipped and logged; the game's commands read the character without checking.

`undo` (or `u`) removes the nearest thing within `undo.within_m` metres of the admin of the class their last spawn (`undo.verbs`) placed, and says how far it was. The host keeps the last `undo.keep` per admin until restart. It goes by class and distance, so it may remove a copy someone else placed. Logged as `console: ... can undo` and `console: undo for`.

Tested on the live host with one player: ten admin lines in a row each ran once; with no admins, `HealMe`, `GetCoords` and `mp who` were dropped; a denied command through `ExecuteForAll` was refused; `mp DestroyAll <class>` removed a vehicle that had slowed the host from about 700 frames per ten seconds to about 20; `undo` removed six spawned posters at 2 to 3 m. No crash in the two minutes after the ten lines or the undos.

Not tested:

- The relay check with a second player. With one player the game handles `ExecuteForAll` on that player's PC and never calls the host.
- Removing a sender after a line that could not be stopped.
- Skipping a line for a player who is not in the world yet.

### The admin panel (client mod MoonpoolConsole)

`client-mods/MoonpoolConsole` ships with Moonpool. Players get it only if `plugins.yaml` lists it with `install: {type: local}`. A folder of the same name under `client-mods/` in the data volume replaces it. It grants nothing: the host's gate decides, so non-admins get nothing from it.

- F2 opens the game's cheat panel and pick lists as one palette, top centre: tabs (Item, Spawn, Equip, Macro, History), the command line and the open list. F2 again closes everything. Esc steps back one level. A second press within half a second is ignored.
- With a list open, typing filters it (letters, digits, space, Backspace; `search.keys`). A row shows if it contains every typed word, matched against the item's name or category folder (`tools`, `resource`). Up and Down pick a row; Enter runs it as a click would and the list stays open.
- With no list open, Enter sends the line to the host's gate: a game command as is (`HealMe`), anything else as a console line (`who`, `g tit 10`). A line typed with a list open goes nowhere.
- Unpublished items are hidden unless `search.show_unpublished` is set; the game's `ToggleUnpublished` works only on Development builds.
- The mod sends the line as read after the last typing key, so a last character not in `search.keys` is dropped.
- The list stays slightly see-through (`list.tint` darkens its frame). No Goto button: this build disables goto and warp.

`Scripts/config.lua` holds every setting: key, console word, position, which panel parts stay, what closing closes, log messages, and the game names the mod relies on.

Tested on one PC, build 26496980, through a test harness and through the launcher with real keys: open and close eleven times, answers on screen, three stacked lists closed at once, typed lines reaching the host, and filtering the item list's 208 rows (179 shown, 29 unpublished hidden; 4 for `tit`, 16 for `tools`). Calls into the game fail at random on this build, so each is retried.

## More than one world

Each world needs its own Steam account that owns the game.

```sh
bin/moonpool-instance add family experimental
docker compose -p sn2-family --env-file instances/family/.env up -d --build
bin/moonpool --instance family status
```

## Backups

The game autosaves every 2 minutes, each save stalling the server a second or more. By default the host turns that off once the world is up and saves every `SAVE_EVERY_MINUTES` (10) and after each batch of players leaves. An empty server skips saves and archives; the next player in restarts the timer. A crash can lose up to `SAVE_EVERY_MINUTES` of play. `SAVE_EVERY_MINUTES=0` keeps the game's autosave.

Archives:

- Every 30 minutes into `./backups`, kept 7 days. For remote storage or encryption, copy `backup.env.example` to `backup.env`.
- They hold the saves and the game's Steam userdata folder, not the sign-in or the mod-signing key.
- Lose that key and players' launchers treat the server as new and ask again. Keep a private copy: `docker compose cp sn2:/home/container/mod-signing ./mod-signing`.

```sh
bin/moonpool server backup
ls backups                    # newest last
bin/moonpool server restore backups/<file>.tar.gz Slot1
```

Restore keeps a safety copy of the current saves and hosts again about a minute later. It checks the archive holds a save, not that the save is undamaged. Tested on an empty world with a real join; not with players on.

Two worlds must not share a `BACKUP_DIR`. `bin/moonpool-instance` gives each its own.

## Bring your world

Move a co-op world onto the server so it's there when its old host is offline.

1. On the PC that hosted it, close the game and open its SaveGames folder: `%LOCALAPPDATA%\Subnautica2\Saved\SaveGames` on the public branch, `<Steam library>\steamapps\common\Subnautica2\Subnautica2\Saved\SaveGames` on experimental.
2. Zip the folder, or copy it to the server, and import it:

```sh
bin/moonpool server import SaveGames.zip          # the newest world in it
bin/moonpool server import savegame_2.sav Reef    # one world, renamed
```

Worlds are the `savegame_<n>.sav` files; import ignores the folder's other `.sav` files. It snapshots the current saves, hosts the new world and checks the game loaded it. If not, the previous world is hosted again. The game loads only saves from its own branch and build, so update the game on the old PC first.

`bin/moonpool server export` zips the hosted world (`Slot1.sav` by default). Loading that on a player's PC hasn't been tried.

## Move the server to another PC

The server is the image, two volumes and `.env`. The volumes are `<project>_sn2-data` (game, Steam sign-in, saves) and `<project>_sn2-signing` (manifest key); `<project>` is `COMPOSE_PROJECT_NAME`, `moonpool` unless set. Move all three and the new PC hosts the same world at the same address; a token tunnel's address moves with `.env`. Done once between two Windows PCs with Docker Desktop: about 28 GB over a home network in half an hour.

```sh
# old PC: nobody on, then save and stop
bin/moonpool players && bin/moonpool server save
docker compose stop

# new PC, in a checkout of the same commit, with the old PC's .env copied in (it holds your secrets)
ssh old "docker save <the image in SN2_IMAGE> moonpool:backup" | docker load
docker compose create      # makes the volumes with compose's own labels, starts nothing
for v in sn2-data sn2-signing; do
  ssh old "docker run --rm -v moonpool_$v:/d alpine tar -C /d -cf - ." |
    docker run --rm -i -v moonpool_$v:/d alpine tar -C /d -xpf -
done
docker compose up -d
```

- Before starting, compare `find /d -type f | wc -l` in both copies of `sn2-data`, and the save's size and time.
- The new volumes must be empty first; tar leaves stale files in place.
- From Git Bash on Windows, prefix the `docker run` lines with `MSYS_NO_PATHCONV=1`, or `/d` becomes a Windows path.
- Steam signed in by itself from the copied sign-in. If it asks, sign in through the viewer.
- Never run both: they share one Steam account and one tunnel. `docker update --restart=no` on the old PC's containers keeps a reboot from starting them.
- Copy `backups/` for the older archives; the new PC starts its own.
- The image also builds on the new PC: `docker build --build-arg WINE_RUNTIME=tkg -t <the image in SN2_IMAGE> .` (ticks stayed smooth with a player on). The move used the copied image.

## Updates

- Steam can update the game whenever it runs. If the world has saves, Steam starts only after they are copied; `UPDATE_WITHOUT_BACKUP=true` skips that.
- `RESTART_CRON` restarts the game only and never updates it. When the card shows a build players can't join on, run `bin/moonpool server restart`: it warns players, counts down and recreates the container (`--now` skips the countdown). Check nobody's on first.
- `AUTO_UPDATE=false` only stops Moonpool asking Steam to validate the game. Steam can still update it.

A new build hosts only if the loader works on it. The public branch needs nothing from you. Other branches aren't supported out of the box: an experimental build may need a `MemberVariableLayout.ini` and `VTableLayout.ini` that fit it, in `ue4ss-local` in the data volume. That folder is copied over the loader's files on every launch and survives game updates.

- The newest experimental build in the README's table hosted with the default loader plus those two files (member layout measured from that build, vtable layout from the one before).
- Without the member layout the loader crashed before the hosting mod loaded. With only it, the game crashed at the loader's first garbage-collection pass. Both times the host reported no hosted world and waited.
- After an update the files may still fit. If not, the card says Not hosting and that build needs new files.

Moonpool can't make these files, doesn't ship them and doesn't help make them. The older pinned loader takes a set per build in a folder under `ue4ss-layouts`: `MemberVariableLayout.ini`, `VTableLayout.ini`, `UE4SS-settings.ini`, `UE4SS_Signatures`, and the game exe's SHA-256 in `exe.sha256`.

## Console commands

`bin/moonpool diag console` runs one of the game's console commands as a player. Off by default. To turn it on, add `player` to `enabled_commands` in `sn2headless.json` in the data volume (keep the other commands you use) and recreate the host.

## Events and your own automation

No event bus. Two hooks in the data volume, both able to call anything in `bin/moonpool`:

- `hooks/on-event`, if executable, runs on `join`, `leave`, `up`, `restart`, `update` and `outage` with the event and its detail as arguments. Output: `logs/hooks.log`. It runs with the host's rights, like any admin script.
- `crontab` adds your own schedule. Recreate the host after changing it. Output: `logs/cron.log`.

`world time` and `world weather` need `settings` in `enabled_commands`.

```
0 20 * * 5 moonpool notify "Storm coming" && moonpool world weather StormA
```

```sh
#!/bin/sh
[ "$1" = join ] && moonpool notify "$2 is aboard"
```

Logs in `logs/` that only grow are kept to 10 MB plus four older pieces, checked hourly. `game.log` restarts at each launch (the last kept as `game.log.prev`). `join_watch.log` is never cut; the player count is read from it.

## Server mods

- **Pak mods**: `.pak`, `.ucas` and `.utoc` files in `paks-local/` in the data volume. Each launch copies them into the game's `Content/Paks/~mods` and removes ones you've taken out. Mods that change game rules (storage sizes, vehicle stats) usually need to be on the host as well as in `plugins.yaml`; the host decides those in co-op.
- **UE4SS mods**: `ue4ss-local/Mods/<name>/` in the data volume, with an empty `enabled.txt` beside `Scripts`; recreate the host. To remove one, delete it there and from `ue4ss/Mods` in the game folder. Most we've read act on the local player, so they do nothing for players on a host; put those, and mods that change players' PCs, in `plugins.yaml`.

Server mods run with the host's rights and Steam session. Only use ones you trust.

Players' loader: on some builds it needs layout files the UE4SS release lacks, or the game crashes about ten seconds after start. Put a `MemberVariableLayout.ini`, `VTableLayout.ini` and `UE4SS-settings.ini` that work on a player's PC for the current build in `ue4ss-client/` in the data volume.

- The settings file matters too: on experimental build 26496980 the release's guess (engine 5.7, debug build) crashes the game. The working file sets `MajorVersion = 5`, `MinorVersion = 6`, `DebugBuild = false`.
- The publisher serves the pinned loader with those files added, under its own name and sha256. Anyone who can reach the join page can fetch it.
- A player is asked before their own layout files are replaced. Their settings file is replaced only while it is still the launcher's copy.
- The host's own files go in `ue4ss-local/`, not here.

## Discord card

1. Make a channel. Let `@everyone` read and add reactions but not send messages.
2. Channel settings, Integrations › Webhooks › New Webhook; copy its URL. Anyone with it can post there.
3. Set `DISCORD_WEBHOOK_URL=` in `.env` and run `docker compose up -d`. The card appears within a minute and is edited in place.

For mentions on important alerts, set `DISCORD_ALERT_ROLE_ID` to an opt-in role's id.

## Map

`WEB_MAP=true` adds `/map` and puts the live map on the join page, so the card's Join button opens both. The button stays clickable while the server is down or starting; the page then says so. Anyone with the link can fetch `map.json`, which holds everything the page draws, fogged or not.

| Shows | Leaves out |
|---|---|
| Each player where they were `MAP_DELAY_MINUTES` ago (15; 0 is the last position), coloured by depth, as "Player 1" etc. Names with `MAP_PLAYER_NAMES=true`, never with `SHOW_PLAYER_NAMES=false`. A player who left stays as a faded marker for an hour | Bases (the game's base position can be far from its rooms; name a signal there instead) |
| Lifepods and PDA signals everyone can see, by name. A signal shows once it has stayed put for the delay, so a vehicle's shows where it was left | Signals hidden by default, such as undiscovered story places, and admin commands |
| Fog over places nobody has visited, clearing on the same delay, when a map picture is set. The Discord picture too | Players, explored places and signals following something with `MAP_PLAYERS=false`; signals with `MAP_SIGNALS=false`. Both apply to `map.json` too |

Moonpool ships no map picture. To set one:

```sh
docker compose cp map-background.example.json sn2:/home/container/map-background.json
```

- One entry per branch: a picture, or a list laid side by side. Each `url` is a tile address with `{z}`, a picture address or a file in the data volume. `bounds` are left, top, right, bottom in game units. Name the picture's author and licence in `credit`; the page shows it.
- Your own picture: stand on two far-apart spots and run `bin/moonpool map where <player>` on each, note their pixel positions, then `bin/moonpool map bounds` works out the edges. No rotation.
- The experimental build has region pictures under `Subnautica2/Content/Debug`, bounds in `maps.json`. They're the studio's files; Moonpool doesn't ship or fetch them, and publishing them is between you and the studio.
- The example uses [joric's Subnautica 2 tileset](https://github.com/joric/subnautica2_tileset), loaded by players' browsers from joric's site: a community capture from May 2026, before the experimental branch. Newer builds may differ, and no capture of experimental is known. Its Unlicense covers joric's work, not the game's rights.

The page:

- `/map.png` is a still with link preview tags. `/map?embed=1` hides the side card, for an iframe.
- The address holds the view (`#x=..&y=..&z=..`, `hide=fog,signals`, `follow=<name>`), so a copied link opens the same place.
- Overlapping markers merge into a numbered one. The card lists players and places with a name filter.
- Clicking a player follows them, draws their last 240 positions seen by that page, and asks the browser to keep the screen on. With `SHOW_PLAYER_NAMES=false` numbers are reassigned when the set changes, so a follow can jump to someone else.
- Pages refresh every `MAP_REFRESH_SECONDS` (60, minimum 10). The host writes every 30 s, so under 30 gains nothing. Delay 0 shows roughly where you are now, to everyone with the link.
- The page's libraries and icon font load in the viewer's browser from cdnjs.cloudflare.com and cdn.jsdelivr.net (listed in `NOTICE`). `/map.png` is drawn on your host from the same tiles.

## Make it yours

Change what players see from the data volume.

```sh
docker compose cp sn2:/opt/sn2/web/theme.css theme.css
docker compose cp theme.css sn2:/home/container/templates/theme.css
docker compose cp sn2:/opt/sn2/web/join.html.j2 join.html.j2
docker compose cp join.html.j2 sn2:/home/container/templates/join.html.j2
```

- `templates/theme.css`: every colour, font, size and edge of the join page, map page and map still. Pages pick it up on refresh.
- `templates/join.html.j2`: the join page. A copy that fails to render is logged and the shipped page used. It gets `world`, `join`, `friend`, `refresh`, `banner`, `modnote` (the launcher button and the mod list), `mod_action` and `mod_list` (the same, split), `mods_published`, `build`, `branch`, `branch_label`, `map` (the map still, or empty when the map is off; the page then embeds `map.html?embed=1`), `map_facts` (such as `15 min behind`, `2 players`), `game` (`GAME_NAME`, or Subnautica 2) and `theme` (a fingerprint; link `theme.css?{{ theme }}`).
- `templates/banner.png` (or `.jpg`, `.jpeg`, `.webp`, `.gif`): a picture at the top of the join page, full card width, served as is.
- `templates/map.html`, from `web/map.html`: a whole page you own, scripts included.
- `card.yaml`, from [card.example.yaml](../card.example.yaml): the Discord card's wording. Layout and buttons stay. A bad line is logged and the shipped one kept.

## When something's wrong

| Problem | Do |
|---|---|
| Not sure the host is right | `bin/moonpool diag verify-fresh` checks each stage from Steam to the hosted save |
| No session | `bin/moonpool status`, then `bin/moonpool logs game` |
| Join Game is missing | check in the viewer that Steam is signed in and on the right branch |
| A player connects and drops | compare branch and build, then `bin/moonpool logs join_watch` |
| The game won't install | `bin/moonpool diag screenshot shot.png` |
| `clock jumped -1 secs` repeating in `bin/moonpool logs web` | the PC's clock is off. On the PC: `Start-Service w32time; w32tm /resync /force` (seen on a test host with Docker Desktop and Windows Time stopped) |
| Choppy while admins run many console commands | each can stall the server (on a test host, 81 in twenty minutes gave 30 frames over 1 s, against 8 to 10 around it). Run big batches when nobody's on |

`bin/moonpool diag bundle` makes one zip for whoever helps you: game, UE4SS and service logs, status files, the last hour of `tick-report`, the Wine and sync in use, and a summary. The values of `DISCORD_WEBHOOK_URL`, `CURSEFORGE_API_KEY`, `GITHUB_TOKEN`, `VNC_PASSWORD`, `STEAM_BRANCH_PASSWORD`, `TUNNEL_TOKEN` and any Discord webhook address are removed. The Steam session, `.env`, viewer password, mod-signing key and saves are never read. Player names and Steam IDs stay; share it only with someone you trust.

Choppy play:

```sh
docker compose exec sn2 python3 /opt/sn2/bin/tick-report.py --from 2026-11-12T20:00 --window 10
```

Per window (UTC): slow frames (`MaxTickInterval`) with median, p95, p99 and counts over 0.5 s and 1 s, moves dropped as too old (`ServerMove expired`), game autosaves, host saves, console commands run as a player, and player count. Compare windows with the same player count.

Known gaps: this build refuses `Warp`, so players can't be moved. The hold during the launch cinematic is unproven.

## Diagnostic switches

Not in `.env.example`; the defaults work. Set one in `.env` only to rule something out, then recreate the host.

| Setting | Default | What it does |
|---|---|---|
| `GAME_APP_ID` | `1962700` | Steam app id of Subnautica 2 |
| `NULLRHI_ARGS` | `-nullrhi -unattended -log` | Engine arguments; `-nullrhi` is added back if missing (no GPU) |
| `WINE_SYNC` | `auto` | With an image built with `--build-arg WINE_RUNTIME=tkg` (wine-tkg-staging-fsync 10.10): `auto` and `fsync` use fsync, `esync` uses esync, `off` uses neither. The default WineHQ image has neither, so only `auto` and `off` apply. The game's launch log says which is in use |
| `UE4SS_AT_START` | `true` | UE4SS loads at process start through its `dwmapi.dll` proxy |
| `UE4SS_TAG` | `experimental` | The upstream release tag the pinned loader is fetched from |
| `NATIVE_MSVC` | `1` | Microsoft's C++ runtime for the game process only |
| `HOST_PRUNE` | `true` | Takes the host account out of the player list |
| `HIDE_HOST_BODY` | `true` | Hides the host account's body in the world |
| `CLIPBOARD_BRIDGE` | `true` | Copy and paste through the viewer's clipboard panel |
| `S6_SERVICES_GRACETIME` | `210000` | Milliseconds the services get to stop: warning plus save wait plus 30 s |
| `S6_KILL_GRACETIME` | `5000` | Milliseconds before leftover processes are killed |
