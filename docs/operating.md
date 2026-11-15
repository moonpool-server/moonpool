# Running Moonpool

Settings are explained in `.env.example`. Commands are in `bin/moonpool help`. This guide covers sizing, the Steam sign-in, letting players in, mods, in-game admin, backups, moving and updating the server, the map, changing the pages, and what to do when something goes wrong.

## Size

On a test host with 2 players the server used 2.3 cores and 6 GB of memory. For 4 players, plan on about 4 cores, 8 GB of memory, 40 GB of SSD and 10 Mbit upload. That 4-player line is scaled up from the 2-player measurement, not measured.

8 players is a guess at 6 cores 12 GB 60 GB and 25 Mbit. `metrics.csv` in the data volume shows what your host really uses

A game left at full frame rate with nobody in uses about 3.3 cores on a test host. With the friends preset the host lowers its frame cap to `IDLE_MAX_FPS` (10) once the world has been empty for `IDLE_SLOW_MINUTES` (2), and puts `SERVER_MAX_FPS` back when a player's login shows in the game log, or on the next roster check if the log missed it. There the empty server's container dropped to about two-thirds of a core, and a join made while it was lowered took as long as one made at full rate. Lower caps save little more (the game process used 60% of a core at 10, 51% at 5 and 32% at 1, with the engine's worker threads and the lobby's voice room making up the rest) and have not been tested with joins. If the host can't send the command yet, it tries again on the next check. `IDLE_MAX_FPS=0` turns it off; with `PRESET=stock` it is off unless you set it. The clock freeze (`IDLE_FREEZE_MINUTES`) and the stop (`IDLE_STOP_HOURS`) are separate settings. Stopping frees the rest of the CPU and memory, but a stopped game can't be joined until it is started again

A joining player's loading screen waits for the world's data, which the server sends at most `NET_MAX_CLIENT_RATE` bytes a second to each player: 300000 with the friends preset, and the game's own 100000 with `PRESET=stock`. On a test host a join sent about 1.4 MB, the busiest second about 160 KiB, and the loading screen took 15 s instead of 31 s. Each player who is joining can use up to that much of your upload at once; `NET_MAX_CLIENT_RATE=100000` gives the game's default under the friends preset

## Signing in

The viewer controls a signed in Steam so keep it off the internet. It always asks for a password, made at first start unless you set `VNC_PASSWORD`; `bin/moonpool diag viewer` shows it. VNC uses only the first 8 characters, and its handshake is not encrypted. Inside Docker the viewer listens on every interface so the password is what keeps other containers out. Use an SSH tunnel or Tailscale to reach it from elsewhere because they're stronger than a VNC password, even if you bind it to your LAN with `VIEWER_BIND=0.0.0.0`

Use the hosting account with Steam Guard on and pick Remember me. To paste open the noVNC side panel and put it in the clipboard there then press Ctrl+V in Steam

Moonpool doesn't ask for your password or keep it, and it's not in `.env`: you type it into Steam through the viewer. The sign in stays in the data volume and anything running in the container can use it. To accept friend requests by itself Moonpool reads the Steam client's own web session out of its cookie store in the volume and talks to Steam as that account, and it reads which lobby the account is in through the same session for the join link; `AUTO_ACCEPT_FRIENDS=0` turns the accepting off and you accept requests in the viewer. So use a dedicated account, keep Steam Guard on and keep the volume private

Lost the machine? Deauthorize devices in Steam and change the password. `docker compose down -v` deletes the world and its saves for good

## Joining

The game needs no forwarded port. To let a player in:

1. Invite them: `bin/moonpool players invite <steamid64 or profile link>`.
2. They send the hosting account a friend request.
3. You accept it in the viewer. With `AUTO_ACCEPT_FRIENDS=1`, Moonpool accepts invited players within a minute instead, using the host's Steam web session.
4. They press Join Game or use the join page.

`ALLOWLIST_ONLY=false` lets in anyone who asks, not only invited players. With `AUTO_ACCEPT_FRIENDS=0`, Moonpool still reads the waiting requests once a minute through that web session, without accepting or refusing any. The Discord card and `bin/moonpool status` show how many it would let in (never a banned player), and `status` names up to five when `SHOW_PLAYER_NAMES=true`.

Anyone already friends with the account can join until you remove them from its friends in the viewer or with `bin/moonpool ban add`. Everyone needs the same `STEAM_BRANCH` and game build

`moonpool ban add <name>` removes a matching player whenever they join, and `players kick` only removes them for now. `ban add <steamid64>` also takes them off the host's friends list, but only with `AUTO_ACCEPT_FRIENDS=1`; without it they can still join until you remove them in the viewer

## Public address

Players open the join page and fetch mods on port 8081; the game itself needs no open port. Pick one way for them to reach it:

- **Quick tunnel**, no setup: `TUNNEL=quick` and `COMPOSE_PROFILES=tunnel` in `.env`. The address is free and random and changes whenever the tunnel restarts, for example after a reboot. The Discord card and `bin/moonpool status` always show the current one, so send friends there rather than a saved link.
- **Stable, no domain**: [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) on the host, `tailscale funnel --bg http://127.0.0.1:8081`, then `SN2_PUBLIC_URL=https://<machine>.<tailnet>.ts.net`, `TUNNEL=off` and `MODS_BIND=127.0.0.1`. It's free and in beta, with bandwidth limits Tailscale doesn't state, so try a mod download through it.
- **Your own domain** on Cloudflare: the tunnel is free on Cloudflare's free plan; the domain is the cost. A domain bought elsewhere is added to Cloudflare on the free plan and its name servers set to the two Cloudflare gives. In Cloudflare's dashboard, under Networking, Tunnels, create a tunnel, choose Docker and copy the token from the command it shows. Add a route of type Published application with your hostname and the service `http://sn2:8081`. Then set `TUNNEL=token`, `COMPOSE_PROFILES=tunnel-token`, `TUNNEL_TOKEN=<the token>` and `SN2_PUBLIC_URL=https://<your hostname>` in `.env` and recreate the host. The token lets anyone run your tunnel, so keep it out of chat, screenshots and the repo
- **Your own network only**: `http://<this machine's address>:8081/join`, nothing else needed.

Never forward the viewer's port 8080, and don't put 8081 on the internet as plain http.

## Xbox and Game Pass players

Experimental. They can't be invited through Steam. They add the hosting account by its in-game friend code and join from the game's own friends list. The game makes that code only while its Friends screen is open, so `bin/moonpool diag friend-code` opens that screen the way a click would, reads the code and closes it again. Run it once while nobody is on, or with `--force` while players are. Each run makes a new code, and the last one survives restarts. From then on it shows on the Discord card and in that command. It's marked experimental because it's read off the game's own screen

## Mods

```sh
cp plugins.example.yaml plugins.yaml   # edit it with any editor
bin/moonpool mods publish plugins.yaml
bin/moonpool mods list
```

An entry needs the mod's download link: a GitHub release file, a CurseForge file page or a Nexus file page. CurseForge needs your own API key in `.env` (`CURSEFORGE_API_KEY`, free at console.curseforge.com) and a mod whose author allows distribution; otherwise players download that one from its page

The join page shows each mod's `summary` (yours from `plugins.yaml`, or when you give none the project's own one-line description from GitHub or CurseForge) and, for a GitHub repository or a CurseForge project, its stars or downloads, last update and author. The host reads them from GitHub's and CurseForge's APIs at most every six hours (`MOD_STATS_MAX_AGE` seconds) and keeps the last numbers when a read fails. CurseForge's need the same key. GitHub allows 60 unauthenticated reads an hour; a `GITHUB_TOKEN` in `.env` is used if set

A Nexus file needs `bin/moonpool mods pin "<name>" <file.zip>` once, and so does a CurseForge file whose author keeps it on CurseForge (the server never fetches or serves those; the pin must be the file CurseForge lists). Players then download it themselves and the launcher checks it matches

A mod that ships `.pak` files instead of Lua needs `kind: pak` on its entry. The launcher shows players a box for each mod: mandatory ones are ticked and locked, optional ones are ticked unless the entry says `default: false`. What a player ticks is remembered per server. The boxes come back when a mod is added or changes, with each new or changed one marked

Play with mods turns the mods on only until Subnautica 2 closes, so starting the game from Steam loads none of them. If the launcher is killed mid-game, the next run or the Subnautica 2 (without Moonpool mods) shortcut turns them off. The launcher is Steam-only, so Xbox and Game Pass players join without mods

When a player has trouble, ask them to run the Subnautica 2 (collect logs for the host) shortcut in the Start menu, or `moonpool.ps1 -CollectLogs`. It puts one zip on their Desktop and shows it in Explorer: the launcher's log, the game's `Subnautica2.log`, UE4SS's log and settings, the record of what Moonpool placed, the names of crash folders and the versions. Their Windows user and PC names are taken out, crash dumps are left out because they hold memory, and nothing is uploaded: they send you the file themselves. It isn't anonymous: the game's and UE4SS's logs still name your server, its players and Steam IDs, so it should go only to the host. The launcher's error window points them to the same shortcut.

To take the launcher off a PC, close Subnautica 2 and run `powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Moonpool\moonpool.ps1" -Uninstall` in PowerShell. It removes every game file it placed that is still as it placed it, switched on or off, and the folders that leaves empty, then its `moonpool:` link handler, its shortcuts and its own folder. A file you changed since stays and is named. When the launcher finds files it didn't place where a server's mods go, it asks before replacing them and keeps a copy of each in `%LOCALAPPDATA%\Moonpool-replaced`, which uninstalling leaves alone; it doesn't put them back itself. With `-Adopt` it replaces them without asking and keeps no copy. Steam's Verify integrity of game files restores the game's own files

## In game admin

Put each admin's Epic ID in `ADMINS`, or one per line in `control/admins.txt` in the data volume (a note may follow the ID after a space; `#` starts a comment). The file is read again while the host runs, so adding or removing an admin there needs no restart; `ADMINS` is read at start. The UE4SS log prints `player NAME eos=...` when someone joins. Names and Steam IDs don't count because a client can claim those

Admins give orders from inside the game with nothing installed: rename any PDA signal to a command and the host does it, then writes the answer back into the signal's name, green for done and red for refused

```
!help                 the list
!kick NAME            remove a player
!time 12:00           set the clock
!weather DA_Storm     set the weather
!slots 8              change the player cap
!ping                 where everyone is, for admins; your own spot for anyone
!cmd LINE             one of the game's console commands, run on the host as you
```

`!cmd` is the same door as `bin/moonpool diag console` and is off until `player` is in `enabled_commands` (see Console commands below)

`!mp LINE` is the admin console: anything the game's console takes, plus shortcuts and lookups, so nobody needs to know the game's internal names. It is on with `player` in `enabled_commands`, like `!cmd`

```
!mp g cop 10              Give the only item whose name starts with cop, 10 of it
!mp g 10 titanium ingot   the name's words and the number in any order, no quotes needed
!mp g tit                 an unclear name asks: tit? 1 Titanium  2 Titanium Ingot
!mp 2                     ...and a bare number answers it
!mp h                     a shortcut with several lines: heal, then oxygen, food and water to 100
!mp @john h               heal the player whose name matches john; @all and @host work too
!mp f titan               find items, places, players and tags by name, with their ids
!mp l items cop           list one kind, filtered
!mp w                     who is on, with their Epic ID and ping
!mp SomeConsoleCommand 3  any other line goes to the game as typed
!mp .                     the last line again
```

Every word, shortcut and reply comes from `console.json` (the shipped one is `mod/SN2SlotFreeHost/console.json`). To change them, put your own `console.json` in the data volume with only the keys you change, then recreate the host. It is merged over the shipped one key by key: entries in an object such as `commands` are added to the shipped ones, and a list such as `deny` replaces the shipped list. For example, a shortcut `full` that heals and fills oxygen:

```json
{
  "commands": {
    "full": { "aliases": ["full"], "lines": ["HealMe", "attr oxygen 100"] }
  }
}
```

- `commands` maps a word to the game's console lines. Arguments are looked up by kind; `give` in the shipped file shows how.
- `on_ambiguous: first` takes the best match without asking.
- `deny` stops commands that crash or wipe the world. An empty list allows everything, but only in the shipped file: an empty list in your own `console.json` is ignored and the shipped list stays.
- `line_gap_ms` (1000 as shipped) is the gap between the lines of one order, because each can stall the server for a second or so.

Replies come back in the signal's name, which shows about 40 characters, and as a game notification on the sender's screen.

- Kits are the game's own: `RunMacro <name>` runs a text file from the game's `Content/Macros` folder, one console line per row, and the cheat panel has a Macro button that lists them. The files are read on the admin's PC, and the host checks each line as it arrives.
- `!mp l commands` lists the game's own console commands, read from the host's cheat manager class once the host is in the world.
- Places aren't listed: the host gives the console no places yet, so `!mp l places` and `!mp f` find none.
- `!mp c` lists the world cheats that are on, of the tags named under `tags` in `console.json`. The game answers for one tag at a time and has no list of its own. The same names are in `status.json` as `cheats`.

`off` (or `normal`) is a shortcut in `console.json` that puts back what can be put back by name: it runs `DayOnly 0` and `RemoveGlobalTag` for each cheat tag in `tags`. On this build every cheat, god mode and invisibility included, is a world tag, so `off` turns it off for everyone. It removes tags rather than running `god` or `fastbuild` again, because those commands toggle and ignore a number (`FastBuild 0` turns fast build on). The game's `QuickNav` macro also changes this PC's fog and speed, which only its `NormalNav` macro puts back. The game's `RemoveTag` and `AddTag` change a tag on the one player who runs them, not the world's: the game answers "removed" and the world's cheat stays on, so `tag+`, `tag-` and `off` use the `Global` commands, which are the ones `cheats` reads. `FastSwim` changes only the admin's own PC and is not a tag; run it again to turn it off. So after `Superman` or `SculptDebug`, `off` clears everything but fast swim, and after `QuickNav` the game's `NormalNav` puts back fog, speed and swimming.

The game's own macros (its `Content/Macros` folder on each admin's PC, one command per line; a file added there shows in the Macro list) and how each is undone, as run from the panel on this build:

| Macro | What it does | Undo |
|---|---|---|
| Base Pack, Equipment Pack, Starting Items | gives or equips items (Starting Items' `OxygenTankSmall` is not found on this build) | nothing to undo |
| QuickNav | no fog, speed 10, fast swim on this PC; day, frozen at noon, for the world | the game's `NormalNav` |
| Superman | `god`, `fastbuild 1`, `unlockall`, `invisible` (all toggles: a cheat already on turns off), fast swim | `off`; `FastSwim` again for swimming |
| SculptDebug | habitat builder, then the toggles `god`, `freebuild`, `unlimitedpower` | `off` |
| SculptDebugNoSupports | SculptDebug, then `BaseToggleSupportCheck` | `off`, and `BaseToggleSupportCheck` once more: the game keeps no tag for it and says nothing, so the host cannot tell whether it is on |
| damagedebug | four `giveability` lines | nothing: the game answers "Could not find blueprint" for each on this build |

Cheat lines an admin's game forwards (a typed line, a pick from a list, each line of a macro) wait in a queue of their own: one every `cheat_gap_s` (1 as shipped, at most one per poll of the mod, every 2 s), at most `cheat_per_sender` (12) waiting per admin, so a macro of the game runs whole. Each admin can give one order every 3 seconds. The host then runs at most one order every 10 seconds, whoever sent it (`admin_gap_s` in the mod's `config.json`), because each console command can stall the server for a second or two. Orders wait their turn: up to 3 per admin and 20 in all, beyond which the signal answers Busy. A signal renamed by someone not in `ADMINS` is ignored without a reply so nobody can paint other players' signals red

### The game's own cheat panel

The game carries a cheat line from any client to the host (`SN2PlayerController:ServerCheat`) and runs it without checking who sent it. The game ships no way to open its cheat panel, but a client mod that shows it is enough to send lines. The game runs such a line through the sender's cheat manager, so the host mod takes that off the sender's controller for the length of the call and puts it back after: the game's own code then runs nothing. A line from someone in `ADMINS` is run by the host mod instead, as it was sent, unless `deny` in `console.json` names it and only with `player` in `enabled_commands`; a line from anyone else is dropped and logged as `cheat gate: dropped`. The game's `ExecuteForAll` does not use that call: the sender's game asks the host to pass a message on a cheat channel to every player's game, and each runs the command as its own player, so an admin's game would send it on with an admin's rights. The host passes such a message only from an admin and only when `deny` does not name its command; otherwise it changes the message's channel to one nobody listens on and logs `cheat gate: dropped … on GameplayMessage.Cheat…` (`cheat_channel`, `blocked_channel` in `console.json`).

A line that starts with the console's word (`signal_word` in `console.json`, `mp` as shipped) is a console line: `mp g tit 10` sent this way is the same as `!mp g tit 10` in a signal. The console's answer is shown to the sender as one of the game's own notifications, for `reply_seconds` (8 as shipped). These lines wait their turn in the same queue as signal commands: one every `admin_gap_s`, at most three waiting per admin. A line for a player whose character is not in the world yet is skipped and logged, because the game's own commands read the character without checking. If the cheat manager can't be taken off, the game runs the line and nothing can call it back: the log says `cheat gate: COULD NOT STOP`, and a sender who is not an admin is removed from the game (`on_gate_failure` in `console.json`; `log` only logs). `deny` reads a line's first word, so the commands that carry other commands, `ExecuteForAll` and `RunMacro`, are on it; a macro picked in the panel is not affected, because the admin's game sends its lines one at a time and each is checked.

`undo` (or `u`) takes back the sender's last spawn: when an admin's own line is one of the game's spawn commands (`undo.verbs` in `console.json`) and names an item, the host remembers the class that item puts in the world, read from the item's own data, the last `undo.keep` per admin, until the host restarts. `undo` then removes the nearest thing of that class within `undo.within_m` metres of the admin and says how far away it was. It goes by class and distance, not by which one was spawned: with several of the same thing close by, the nearest goes, whoever placed it. Every remembered spawn and every undo is in the host's log (`console: ... can undo`, `console: undo for`).

Tested on the live host with one player:

- Ten admin lines in a row each ran once, with no crash in the two minutes after.
- With the admin list emptied, that player's `HealMe`, `GetCoords` and `mp who` were dropped and the game ran nothing.
- A denied command sent through `ExecuteForAll` was refused, and the host could still save.
- An engine cheat sent as a console line (`mp DestroyAll <class>`) removed a vehicle that had slowed the host from about 700 frames per ten seconds to about 20.
- Six posters spawned from the panel were each removed by `undo`, at 2 to 3 m, with no crash in the two minutes after.

Not tested:

- The relay check with a second player. With one player the game handles `ExecuteForAll` on that player's own PC and never calls the host.
- Removing a sender after a line that could not be stopped.
- Skipping a line for a player who is not in the world yet.

The gate takes the cheat manager away instead of changing the line's text, because changing the text in place corrupted the game's memory and crashed the host.

### The admin panel (client mod MoonpoolConsole)

`client-mods/MoonpoolConsole` comes with Moonpool. It is not offered to players until you list it in `plugins.yaml` with `install: {type: local}`; a folder of the same name under `client-mods/` in the data volume replaces the shipped one.

In the game, its key (F2 as shipped) shows the game's own cheat panel and its pick lists as one palette in one place, top centre: the tab row (Item, Spawn, Equip, Macro, History), a label, the command line, and under them whichever of the game's lists is open, as wide as they are, with the list's own title naming it. History is the same kind of list and behaves the same. The same key closes the panel and everything it opened; Esc steps back one level, lists first, then the panel; a second press within half a second is ignored. While a list is open, typing filters it: the list has the keyboard then, not the command line, so the mod reads the letter, digit, space and Backspace keys itself (`search.keys` in `config.lua`). Rows that do not contain every typed word are hidden, in any order, and a word can be an item's name or its category, the folder its data lives in (`tools`, `resource`). The list's own line under its title shows what was typed and how many rows show. Up and Down move the choice over the rows that show, marked in the game's own selected style, and Enter runs it through the list's own model, as a click does; the list stays open for another pick. The game's own arrows and Enter are not used for this: they count the rows the filter hid, and Enter runs the list's own selection. Items the game itself calls unpublished are hidden unless `search.show_unpublished` is set; the game's `ToggleUnpublished` cannot do this, it answers "Cheat can only be executed on Development builds". The rows are the game's own, only shown or hidden, and a line entered while a list is open is not sent anywhere. With no list open, a line is sent to the host as a cheat line, the way the game sends its own, and the host's gate checks the sender: one of the game's own commands as it is (`HealMe`), anything else as a console line (`who`, `g tit 10`), answered with a notification. The game's own Enter does not run a line typed in this panel (the panel is not in its menu stack). The game runs a line on Enter in its own code and has cleared it by the time the mod sees Enter, so the mod reads the command line after each typing key and sends what it last read; a line whose last character has no key in `search.keys` is sent without it. The panel's own blur sits behind its block and the list's frame is darkened (`list.tint`); the blur cannot go behind the list, because below the game's lists the panel loses Esc to the game's own menu, so the list stays slightly see-through. The Goto button is not shown: the game's goto and warp commands answer "This command is disabled in this build". The mod decides nothing about who may do what: the host's gate above does, so a player who is not an admin gets nothing from it.

`Scripts/config.lua` is the only place to change it: the key, the console's word, where the panel sits, which parts of the game's panel stay, what closing closes, the log messages, and the game's own names the mod relies on.

Tried on one PC on game build 26496980 through a test harness that calls the mod's functions: shown and closed eleven times in a row with the world's own actions usable afterwards; `who` and `g tit 1` answered on screen; three lists opened on top of older ones all closed by one close; a line typed on the keyboard appeared in the command line and reached the host. The search, called with a query: of the item list's 208 rows, 179 show with nothing typed (29 unpublished hidden), 4 for `tit`, 1 for `ing tit`, 16 for `tools`, none for `zzzz`; the loop ran 40 s with a list open. The first press finds the panel's parts in about 0.1 s. Each call into the game is retried, because calls fail at random on this build. Installed through the launcher on that PC and tried there with real keys: F2, `item a` and Enter opened the item list; typing `tit` left 4 rows with `Filter: tit_` over the command line; Backspace and `tools` gave the tools; Esc closed the list, then the panel.

## More than one world

Each world needs its own Steam account that owns the game

```sh
bin/moonpool-instance add family experimental
docker compose -p sn2-family --env-file instances/family/.env up -d --build
bin/moonpool --instance family status
```

## Backups

The game saves the world every 2 minutes by itself, and each save stalls the server for a second or more, which players feel as rubber-banding. By default the host switches that autosave off once the world is up and saves it itself every 10 minutes (`SAVE_EVERY_MINUTES`) and once after each batch of players leaves. While nobody has been in since the last save it skips the schedule, so an empty server writes no new saves and no new backup archives; the next player in starts the 10 minutes again rather than meeting a save on the way in. It sends the game's `ToggleAutoSave` only right after it has seen the game autosave, so the switch is never flipped the wrong way, and again if the game keeps autosaving. A crash can lose up to that many minutes of play. `SAVE_EVERY_MINUTES=0` leaves the game's own autosave alone

Saves are copied every 30 minutes and kept 7 days in `./backups`. For remote storage or encryption copy `backup.env.example` to `backup.env`. Archives hold the saves and the game's own Steam userdata folder and never the account's sign-in, which stays in the volume. They don't hold the mod-signing key either, which lives in its own volume: if you lose it, players' launchers treat the server as a new one and ask again. To keep a copy, `docker compose cp sn2:/home/container/mod-signing ./mod-signing` and store it somewhere private

```sh
bin/moonpool server backup
ls backups                    # newest last
bin/moonpool server restore backups/<file>.tar.gz Slot1
```

Restore keeps a safety copy of your current saves and then hosts again, about a minute after the command returns. It checks that the archive reads and holds a save, not that the save is undamaged. Tested on an empty world with a real join. Restoring with players on hasn't been tested

Two worlds must not share a `BACKUP_DIR`: they overwrite each other's archives. `bin/moonpool-instance` gives each its own

## Bring your world

A world you already play in co-op can move onto the server, so it's there when the old host is offline. On the PC that hosted it, open `%LOCALAPPDATA%\Subnautica2\Saved\SaveGames` (for the experimental branch also look in the game's own `Subnautica2\Saved\SaveGames` folder under its Steam library) and take the newest world, a `.sav` like `savegame_2.sav` with its numbered `.bak` files. Zip them or copy the folder to the server, then

```sh
bin/moonpool server import savegame_2.zip
bin/moonpool server import SaveGames/ Reef    # another name for it
```

It snapshots the current saves, re-hosts on the imported world and waits for the game to say it loaded and for the session to come up. The game only loads a save from its own build and branch, so bring a world from the same branch as the server and update the game on that PC first. A save it can't load is taken back out and the previous world hosted again. To take a world home `bin/moonpool server export` writes a zip, from a quiet copy of the saves, to drop into a player's SaveGames folder

## Move the server to another PC

Everything the server is lives in three places: the image, the two volumes (`<project>_sn2-data` with the game, the Steam sign-in and the saves, and `<project>_sn2-signing` with the manifest key; `<project>` is `COMPOSE_PROJECT_NAME`, `moonpool` unless you set it) and `.env`. Move all three and the new PC hosts the same world at the same address; with a token tunnel the address moves with `.env` and the router needs no change. Done once between two Windows PCs with Docker Desktop, about 28 GB over a home network in half an hour:

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

- Compare before you start it: `find /d -type f | wc -l` in both copies of `sn2-data`, and the size and time of the save
- The new PC's volumes must be empty first: tar adds to what is there and leaves a stale file in place
- From Git Bash on Windows put `MSYS_NO_PATHCONV=1` in front of the `docker run` lines, or `/d` is rewritten into a Windows path
- Steam signed in by itself on the new PC from the copied sign-in. If it asks again, sign in on the viewer page as the first time
- Never start both: they share one Steam account and one tunnel. On the old PC `docker update --restart=no` on its containers keeps a reboot from bringing it back
- Copy `backups/` too if you want the older archives; the new PC starts its own every 30 minutes
- The image also builds on the new PC (`docker build --build-arg WINE_RUNTIME=tkg -t <the image in SN2_IMAGE> .` in the checkout, ticks stayed smooth with a player on); the move itself ran the copied image

## Updates

Steam can update the game whenever it runs. If the world has saves, Steam starts only after they are copied. A scheduled restart (`RESTART_CRON`) restarts the game alone and never updates it, so when the card shows a new build players can't join on, run `bin/moonpool server restart`, which recreates the container after a countdown warning players (`--now` skips it). `UPDATE_WITHOUT_BACKUP=true` skips that check. `AUTO_UPDATE=false` only stops Moonpool asking Steam to validate the game; Steam can still update it, so it does not hold a build. Check nobody's online before you recreate the host

A new build only hosts if the loader works on it. The public branch uses a loader that needs nothing from you. Other branches aren't supported out of the box: on an experimental build you may have to supply a `MemberVariableLayout.ini` and a `VTableLayout.ini` that fit that build, in `ue4ss-local` in the data volume. That folder is copied over the loader's files on every launch and stays in the volume through game updates.

- The newest experimental build in the README's table hosted with the default loader plus those two files. The member layout was measured from that build; the vtable layout came from the build before it.
- Without the member layout the loader crashed before the hosting mod loaded. With only the member layout the game crashed at the loader's first garbage-collection pass. Either way the host came up, reported no hosted world and waited.
- After a game update the same files may still fit. If they don't, the loader crashes again, the card says Not hosting, and that build needs layout files that fit it.

Moonpool can't make these files for you: on a test server, measuring the object array from the running game gave a different answer each time, a file with only those sections didn't host, and the field sections it also needs can't be read once the loader has crashed. The older pinned loader instead takes a whole set for the build in a folder under `ue4ss-layouts`, with `MemberVariableLayout.ini` `VTableLayout.ini` `UE4SS-settings.ini` `UE4SS_Signatures` and the game exe's SHA-256 in `exe.sha256`. This project doesn't ship these files or help make them

## Console commands

`bin/moonpool diag console` runs one of the game's console commands as a player. It's off by default. To turn it on add `player` to `enabled_commands` in `sn2headless.json` in the data volume, keep the other commands you use in that list and recreate the host

## Events and your own automation

Moonpool has no event bus. It gives you two doors and you decide what happens

`hooks/on-event` in the data volume, if it's executable, runs on each `join` `leave` `up` `restart` `update` and `outage` with the event and its detail as arguments. Its output goes to `logs/hooks.log`. It runs inside the container with the host's rights so treat it like any admin script

`crontab` in the data volume adds your own schedule. Recreate the host after changing it. Its output goes to `logs/cron.log`

The logs in `logs/` that only grow are kept to 10 MB each, with four older pieces beside them (`services.log.1`, then `.2.gz` to `.4.gz`), checked hourly by logrotate. `game.log` starts again at each launch with the last one kept as `game.log.prev`, and `join_watch.log` is left whole because the world's player count is read from it

Those can call anything in `bin/moonpool`. `world time` and `world weather` need `settings` in `enabled_commands` in `sn2headless.json`. For example a storm every Friday evening:

```
0 20 * * 5 moonpool notify "Storm coming" && moonpool world weather StormA
```

Or a greeting in `hooks/on-event`:

```sh
#!/bin/sh
[ "$1" = join ] && moonpool notify "$2 is aboard"
```

## Server mods

A pak mod the host should run goes in `paks-local/` in the data volume as its `.pak` `.ucas` and `.utoc` files; each launch copies them into the game's `Content/Paks/~mods` and removes ones you've taken out. Mods that change the game's rules, such as storage sizes or vehicle stats, usually need to be on the host as well as in `plugins.yaml`, because the host decides those in co-op.

A UE4SS mod the host should run goes in `ue4ss-local/Mods/<name>/` in the data volume with an empty `enabled.txt` beside its `Scripts` folder. Recreate the host to load it. To remove one delete it from there and from `ue4ss/Mods` in the game folder. Most mods we read act on the local player, so on a host they do nothing for players and belong in `plugins.yaml` instead. A mod that also changes something on players' PCs belongs in `plugins.yaml` too. Mods are other people's code running with the host's rights and Steam session so only use ones you trust

Players' loader needs layout files on some game builds, and the UE4SS release doesn't carry them: without them it crashes the game about ten seconds after the start. Put `MemberVariableLayout.ini`, `VTableLayout.ini` and `UE4SS-settings.ini` that work on a player's PC for the current build in `ue4ss-client/` in the data volume. The settings file matters as much as the layouts: the release's defaults leave the engine version and build type to a guess, and on experimental build 26496980 the guess (engine 5.7, debug build) crashes the game; the working file sets `MajorVersion = 5`, `MinorVersion = 6` and `DebugBuild = false`. The publisher then serves the loader as the pinned release with those files added, under its own name and sha256, and the launcher installs them with it. A player who already has different layout files is asked before they are replaced; a settings file is replaced only while it is still exactly the copy the launcher placed, so a player's own edits stay. These are a player's files, not the host's: the host's own go in `ue4ss-local/`

## Discord card

1. Make a channel for the server. In its permissions, let `@everyone` read and add reactions but not send messages.
2. In the channel's settings, Integrations › Webhooks › New Webhook, then copy its URL. Treat it as a password: anyone holding it can post there.
3. Put it in `.env` as `DISCORD_WEBHOOK_URL=` and run `docker compose up -d`. The card appears within a minute and is edited in place from then on.

For mentions on important alerts, make a role people can opt into and set `DISCORD_ALERT_ROLE_ID` to its id.

## Map

`WEB_MAP=true` adds a page at `/map` and a Map button on the Discord card.

**Who can see it.** Anyone with the link can open the page and fetch `map.json`, which holds everything the page draws. The fog is only a view: someone who reads `map.json` sees what it covers.

**What it shows:**

- One marker per player where they were `MAP_DELAY_MINUTES` ago (15 unless set; 0 shows the last recorded position), colored by depth. Players are numbered ("Player 1"). `MAP_PLAYER_NAMES=true` shows their names instead, but never with `SHOW_PLAYER_NAMES=false`. Someone who left stays as a faded marker for an hour.
- Lifepods, and the PDA signals everyone in the game can see, each with its name at its exact position. A signal shows only once it has stood at one place for the delay, so one that moves, such as a vehicle's, shows only where it was left.
- Fog, when a map picture is behind it: the default view darkens everywhere nobody has visited yet and clears in soft patches on the same delay. The Discord picture is fogged the same way.

**What it leaves out:**

- Bases. The position the game gives a base can be far from its rooms, so name a signal at the base to mark it.
- Signals hidden by default, such as story places nobody has found yet, and in-game admin commands.
- With `MAP_PLAYERS=false`: players, the explored places, and signals the game marks as following something. With `MAP_SIGNALS=false`: the signals. Both leave these out of `map.json` as well as the page.

Moonpool ships no map picture. To put one behind the dots, copy a map file into the data volume; its `credit` line is shown on the page, so name the picture's author and licence there:

```sh
docker compose cp map-background.example.json sn2:/home/container/map-background.json
```

The file has one entry per game branch, so public and experimental can use different maps. A branch's entry is one picture or a list of pictures laid side by side. Each `url` is tile addresses with `{z}`, a picture's address or a file you put in the data volume. `bounds` are the picture's left, top, right and bottom edges in game units

The experimental build carries its own top-down region pictures in the game folder under `Subnautica2/Content/Debug`, with their bounds in `maps.json` there. They're the studio's own files. Moonpool doesn't ship or fetch them and putting them on a page is between you and the studio

For your own picture pick two spots far apart that you can find in game. Stand on each and run `bin/moonpool map where <player>`, note each spot's pixel position in the picture, then `bin/moonpool map bounds` works out the edges. The picture can't be rotated

The page carries link preview tags and a still at `/map.png`, so a pasted link shows the map in Discord and the like. `/map?embed=1` hides the card of players and places for an iframe.

**The address** follows the view: `#x=..&y=..&z=..` is the centre in game metres and the zoom, and `hide=fog,signals` lists the layers switched off. A copied link opens the same place with the same layers.

**Markers and the card.** Markers that would overlap merge into one numbered marker. The card lists every player and place, with a box to narrow the list by name, and a click on one goes there.

**Following a player.** A click on a player follows them:

- The map stays on them at each check, and `follow=<name>` goes into the address.
- The last 240 places that open page has seen them at are joined into a path.
- The browser is asked to keep the screen on until the follow ends. Not every browser does.

Hiding Players hides the followed player too. With `SHOW_PLAYER_NAMES=false` the numbers are handed out again whenever the set of players shown changes, so a follow can land on someone else.

**Refresh.** An open page asks for new data every `MAP_REFRESH_SECONDS` (60 unless set, never under 10). The host writes the data every 30 seconds, so less than 30 gains nothing. Players are still shown `MAP_DELAY_MINUTES` behind. For a map beside the game that shows about where you are, set the delay to 0; everyone with the link then sees that too.

**Requests to other sites.** The page's libraries and icon font load in the viewer's browser from cdnjs.cloudflare.com and cdn.jsdelivr.net (listed in `NOTICE`). The still at `/map.png` is drawn on your host from the same tiles, so the choice of tiles is your call there too

The example points at [joric's Subnautica 2 tileset](https://github.com/joric/subnautica2_tileset), which your players' browsers load from joric's site. It's a community capture of the game from May 2026, before the experimental branch opened. It needs no lining up but newer builds may differ and no capture made on experimental is known. Its Unlicense covers joric's work and can't speak for the game's own rights, so that part is your call

## Make it yours

What players see is yours to change, from the data volume, nothing to fork

- The look: every colour, font, size and edge of the join page, the map page and the map's still picture comes from `theme.css`. Copy it out, change the values, put it back as `templates/theme.css`; the pages pick it up on their next refresh

```sh
docker compose cp sn2:/opt/sn2/web/theme.css theme.css
docker compose cp theme.css sn2:/home/container/templates/theme.css
```

- The join page: copy the shipped template out, edit it, put it back as `templates/join.html.j2`. It gets `world`, `join`, `friend`, `refresh`, `banner`, `modnote`, `mods_published`, `build`, `branch`, `branch_label`, `map` (the map's still picture when the map page is on, else empty; the shipped page shows it beside the card on a wide screen, linking to the live map) `map_facts` (what the map shows, as short items such as `15 min behind` and `2 players`) `game` (the game's name, `GAME_NAME` or Subnautica 2) and `theme` (a fingerprint of `theme.css`; link the stylesheet as `theme.css?{{ theme }}` so a changed theme is fetched again). A copy that fails to render is said in the log and the shipped page is used

```sh
docker compose cp sn2:/opt/sn2/web/join.html.j2 join.html.j2
docker compose cp join.html.j2 sn2:/home/container/templates/join.html.j2
```

- A picture at the top of the join page: put it in the data volume as `templates/banner.png` (or `.jpg`, `.jpeg`, `.webp`, `.gif`). It is served as it is, at full card width; delete it and the page goes back to no picture. A template of your own gets its name as `banner`
- The map page the same way, `web/map.html` to `templates/map.html`. It is a whole page you own, scripts and all, so treat it like anything else you publish
- The Discord card's wording: copy [card.example.yaml](../card.example.yaml) to `card.yaml` in the data volume and change any line. The layout and the buttons stay. A line that is not text, too long or uses a placeholder it doesn't have is logged and the shipped line kept

## When something's wrong

- Not sure the host is right: `bin/moonpool diag verify-fresh` checks each stage from Steam to the hosted save
- Asking someone for help: `bin/moonpool diag bundle` saves one zip with the game's, UE4SS's and the services' logs, the status files, the last hour of `tick-report`, the Wine and sync in use, and a summary. The values of `DISCORD_WEBHOOK_URL`, `CURSEFORGE_API_KEY`, `GITHUB_TOKEN`, `VNC_PASSWORD`, `STEAM_BRANCH_PASSWORD` and `TUNNEL_TOKEN` and any Discord webhook address are taken out of the text. The Steam session, `.env`, the viewer password, the mod-signing key and saves are never read. Player names and Steam IDs in the game's logs stay, so share it only with someone you trust
- No session: `bin/moonpool status` then `bin/moonpool logs game`
- Join Game is missing: check in the viewer that Steam is signed in and on the right branch
- A player connects and drops: compare branch and build then `bin/moonpool logs join_watch`
- The game won't install: `bin/moonpool diag screenshot shot.png`
- `bin/moonpool logs web` says `clock jumped -1 secs` over and over. Cause: the PC's own clock is off, and two time syncs inside Docker's Linux pull the clock back and forth. On a test host this was Docker Desktop for Windows with the Windows Time service stopped. Fix: on the PC, `Start-Service w32time; w32tm /resync /force`. There the game kept time by the hardware clock, which stayed right, so it showed only in logs
- Players say it's choppy: `docker compose exec sn2 python3 /opt/sn2/bin/tick-report.py --from 2026-11-12T20:00 --window 10` reads the logs the host already keeps (times in UTC). Per window it gives the slow frames the game logged (`MaxTickInterval`) with their median, p95, p99 and how many went over 0.5 s and 1 s, the player moves the server dropped as too old (`ServerMove expired`), the game's autosaves, the host's own saves, the console commands run as a player, and the player count. Compare windows with the same number of players.
- Players say it's choppy while admins run many console commands. Cause: each console command run as a player can stall the server (on a test host, 81 in twenty minutes gave 30 frames over 1 s, against 8 to 10 in the windows around it). Fix: run big batches when nobody's on

Known gaps: `Warp` is refused by this build so there's no way to move a player. The hold during the launch cinematic hasn't been proven

## Diagnostic switches

These stay out of `.env.example` because the defaults are what works. Set one in `.env` only to rule something out, then recreate the host

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
