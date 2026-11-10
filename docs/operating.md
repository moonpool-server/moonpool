# Running Moonpool

Settings are explained in `.env.example`. Commands are in `bin/moonpool help`. This covers the rest

## Size

4 players need about 4 cores 8 GB of memory 40 GB of SSD and 10 Mbit upload. Measured at 2 players it used 2.3 cores and 6 GB and the 4 player line is scaled up from that

8 players is a guess at 6 cores 12 GB 60 GB and 25 Mbit. `metrics.csv` in the data volume shows what your host really uses

## Signing in

The viewer controls a signed in Steam so keep it off the internet. It always asks for a password, made at first start unless you set `VNC_PASSWORD`; `bin/moonpool diag viewer` shows it. Inside Docker the viewer listens on every interface so the password is what keeps other containers out. Use an SSH tunnel or Tailscale to reach it from elsewhere because they're stronger than a VNC password, even if you bind it to your LAN with `VIEWER_BIND=0.0.0.0`

Use the hosting account with Steam Guard on and pick Remember me. To paste open the noVNC side panel and put it in the clipboard there then press Ctrl+V in Steam

Moonpool doesn't ask for your password or keep it, and it's not in `.env`: you type it into Steam through the viewer. The sign in stays in the data volume and anything running in the container can use it. To accept friend requests by itself Moonpool reads the Steam client's own web session out of its cookie store in the volume and talks to Steam as that account, and it reads which lobby the account is in through the same session for the join link; `AUTO_ACCEPT_FRIENDS=0` turns the accepting off and you accept requests in the viewer. So use a dedicated account, keep Steam Guard on and keep the volume private

Lost the machine? Deauthorize devices in Steam and change the password. `docker compose down -v` deletes the world and its saves for good

## Joining

The game needs no forwarded port. Invite each player with `bin/moonpool players invite <steamid64 or profile link>`. They send the hosting account a friend request, you accept it in the viewer (`AUTO_ACCEPT_FRIENDS=1` has Moonpool accept invited players within a minute, using the host's Steam web session), and they hit Join Game or use the join page. `ALLOWLIST_ONLY=false` lets in anyone who asks. With `AUTO_ACCEPT_FRIENDS=0`, Moonpool reads the waiting requests once a minute through the same Steam web session the lobby lookup uses, without accepting or refusing any, and shows how many of them it would let in (invited players, or anyone with `ALLOWLIST_ONLY=false`, never a banned one) on the Discord card and in `bin/moonpool status`, which also names up to five when `SHOW_PLAYER_NAMES=true`. Anyone already friends with the account can join either way until you remove them from its friends in the viewer, or with `bin/moonpool ban add`. Everyone needs the same `STEAM_BRANCH` and game build

`moonpool ban add <name>` removes a matching player whenever they join, and `players kick` only removes them for now. `ban add <steamid64>` also takes them off the host's friends list, but only with `AUTO_ACCEPT_FRIENDS=1`; without it they can still join until you remove them in the viewer

## Public address

Players open the join page and fetch mods on port 8081; the game itself needs no open port. Pick one way for them to reach it:

- **Quick tunnel**, no setup: `TUNNEL=quick` and `COMPOSE_PROFILES=tunnel` in `.env`. The address is free and random and changes whenever the tunnel restarts, for example after a reboot. The Discord card and `bin/moonpool status` always show the current one, so send friends there rather than a saved link.
- **Stable, no domain**: [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) on the host, `tailscale funnel --bg http://127.0.0.1:8081`, then `SN2_PUBLIC_URL=https://<machine>.<tailnet>.ts.net`, `TUNNEL=off` and `MODS_BIND=127.0.0.1`. It's free and in beta, with bandwidth limits Tailscale doesn't state, so try a mod download through it.
- **Your own domain** on Cloudflare: `TUNNEL=token` and `COMPOSE_PROFILES=tunnel-token` with the tunnel's token.
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

The join page shows each mod's `summary` and, for a GitHub repository or a CurseForge project, its stars or downloads, last update and author. The host reads them from GitHub's and CurseForge's APIs at most every six hours (`MOD_STATS_MAX_AGE` seconds) and keeps the last numbers when a read fails. CurseForge's need the same key. GitHub allows 60 unauthenticated reads an hour; a `GITHUB_TOKEN` in `.env` is used if set

A Nexus file needs `bin/moonpool mods pin "<name>" <file.zip>` once. Players then download it themselves and the launcher checks it matches

A mod that ships `.pak` files instead of Lua needs `kind: pak` on its entry. Everything optional installs by default; a player can leave one out

Play with mods turns the mods on only until Subnautica 2 closes, so starting the game from Steam loads none of them. If the launcher is killed mid-game, the next run or the Subnautica 2 (without Moonpool mods) shortcut turns them off. The launcher is Steam-only, so Xbox and Game Pass players join without mods

To take the launcher off a PC, close Subnautica 2 and run `powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Moonpool\moonpool.ps1" -Uninstall` in PowerShell. It removes every game file it placed that is still as it placed it, switched on or off, and the folders that leaves empty, then its `moonpool:` link handler, its shortcuts and its own folder. A file you changed since stays and is named. A mod or loader of yours that `-Adopt` replaced is not put back, because the launcher keeps no copy of it. Steam's Verify integrity of game files restores the game's own files

## In game admin

Put each admin's Epic ID in `ADMINS`. The UE4SS log prints `player NAME eos=...` when someone joins. Names and Steam IDs don't count because a client can claim those

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

One order every few seconds. A signal renamed by someone not in `ADMINS` is ignored without a reply so nobody can paint other players' signals red

## More than one world

Each world needs its own Steam account that owns the game

```sh
bin/moonpool-instance add family experimental
docker compose -p sn2-family --env-file instances/family/.env up -d --build
bin/moonpool --instance family status
```

## Backups

Saves are copied every 30 minutes and kept 7 days in `./backups`. For remote storage or encryption copy `backup.env.example` to `backup.env`. Archives hold the saves and the game's own Steam userdata folder and never the account's sign-in, which stays in the volume

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

## Updates

Steam can update the game whenever it runs. If the world has saves, Steam starts only after they are copied. A scheduled restart (`RESTART_CRON`) restarts the game alone and never updates it, so when the card shows a new build players can't join on, run `bin/moonpool server restart`, which recreates the container after a countdown warning players (`--now` skips it). `UPDATE_WITHOUT_BACKUP=true` skips that check. `AUTO_UPDATE=false` only stops Moonpool asking Steam to validate the game; Steam can still update it, so it does not hold a build. Check nobody's online before you recreate the host

A new build only hosts if the loader works on it. The public branch uses a loader that needs nothing from you. Other branches aren't supported out of the box. The newest experimental build in the README's table hosted with the default loader plus a `MemberVariableLayout.ini` and a `VTableLayout.ini` in `ue4ss-local` in the data volume, which is copied over the loader's files on every launch. The member layout was measured from that build and the vtable layout came from the build before it. Without the member layout the loader crashed before the hosting mod loaded; with only the member layout the game crashed at the loader's first garbage-collection pass. Either way the host came up, reported no hosted world and waited. The older pinned loader instead takes a whole set for the build in a folder under `ue4ss-layouts`, with `MemberVariableLayout.ini` `VTableLayout.ini` `UE4SS-settings.ini` `UE4SS_Signatures` and the game exe's SHA-256 in `exe.sha256`. This project doesn't ship these files or help make them

## Console commands

`bin/moonpool diag console` runs one of the game's console commands as a player. It's off by default. To turn it on add `player` to `enabled_commands` in `sn2headless.json` in the data volume, keep the other commands you use in that list and recreate the host

## Events and your own automation

Moonpool has no event bus. It gives you two doors and you decide what happens

`hooks/on-event` in the data volume, if it's executable, runs on each `join` `leave` `up` `restart` `update` and `outage` with the event and its detail as arguments. Its output goes to `logs/hooks.log`. It runs inside the container with the host's rights so treat it like any admin script

`crontab` in the data volume adds your own schedule. Recreate the host after changing it. Its output goes to `logs/cron.log`

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

A UE4SS mod the host should run goes in `ue4ss-local/Mods/<name>/` in the data volume with an empty `enabled.txt` beside its `Scripts` folder. Recreate the host to load it. To remove one delete it from there and from `ue4ss/Mods` in the game folder. Most mods we read act on the local player, so on a host they do nothing for players and belong in `plugins.yaml` instead. A mod that also changes something on players' PCs belongs in `plugins.yaml` too. Mods are other people's code running with the host's rights and Steam session so only use ones you trust

## Discord card

1. Make a channel for the server. In its permissions, let `@everyone` read and add reactions but not send messages.
2. In the channel's settings, Integrations › Webhooks › New Webhook, then copy its URL. Treat it as a password: anyone holding it can post there.
3. Put it in `.env` as `DISCORD_WEBHOOK_URL=` and run `docker compose up -d`. The card appears within a minute and is edited in place from then on.

For mentions on important alerts, make a role people can opt into and set `DISCORD_ALERT_ROLE_ID` to its id.

## Map

`WEB_MAP=true` adds a page at `/map` and a Map button on the Discord card. It shows one dot per player where they were 15 minutes ago (`MAP_DELAY_MINUTES`), colored by depth and tagged with their name ("Player 1" with `SHOW_PLAYER_NAMES=false`), plus bases and lifepods. Someone who left stays as a faded dot for an hour. `MAP_PLAYERS=false` leaves players and the explored places out of the page and its data, `MAP_BASES=false` the bases. Everything the page draws is in `map.json`, which anyone with the link can fetch, so the fog hides nothing from someone who reads it. With a map picture behind it, the default view darkens everywhere nobody has visited yet, and clears in soft patches on the same delay. The Discord picture is fogged the same way. Anyone with the link can see it all

Moonpool ships no map picture. To put one behind the dots, copy a map file into the data volume; its `credit` line is shown on the page, so name the picture's author and licence there:

```sh
docker compose cp map-background.example.json sn2:/home/container/map-background.json
```

The file has one entry per game branch, so public and experimental can use different maps. A branch's entry is one picture or a list of pictures laid side by side. Each `url` is tile addresses with `{z}`, a picture's address or a file you put in the data volume. `bounds` are the picture's left, top, right and bottom edges in game units

The experimental build carries its own top-down region pictures in the game folder under `Subnautica2/Content/Debug`, with their bounds in `maps.json` there. They're the studio's own files. Moonpool doesn't ship or fetch them and putting them on a page is between you and the studio

For your own picture pick two spots far apart that you can find in game. Stand on each and run `bin/moonpool map where <player>`, note each spot's pixel position in the picture, then `bin/moonpool map bounds` works out the edges. The picture can't be rotated

The page carries link preview tags and a still at `/map.png`, so a pasted link shows the map in Discord and the like. `/map?embed=1` hides the heading for an iframe. The still is drawn on your host from the same tiles so it's your call too

The example points at [joric's Subnautica 2 tileset](https://github.com/joric/subnautica2_tileset), which your players' browsers load from joric's site. It's a community capture of the game from May 2026, before the experimental branch opened. It needs no lining up but newer builds may differ and no capture made on experimental is known. Its Unlicense covers joric's work and can't speak for the game's own rights, so that part is your call

## Make it yours

What players see is yours to change, from the data volume, nothing to fork

- The join page: copy the shipped template out, edit it, put it back as `templates/join.html.j2`. It gets `world`, `join`, `friend`, `refresh`, `modnote`, `mods_published`, `build`, `branch` and `branch_label`. A copy that fails to render is said in the log and the shipped page is used

```sh
docker compose cp sn2:/opt/sn2/web/join.html.j2 join.html.j2
docker compose cp join.html.j2 sn2:/home/container/templates/join.html.j2
```

- The map page the same way, `web/map.html` to `templates/map.html`. It is a whole page you own, scripts and all, so treat it like anything else you publish
- The Discord card's wording: copy [card.example.yaml](../card.example.yaml) to `card.yaml` in the data volume and change any line. The layout and the buttons stay. A line that is not text, too long or uses a placeholder it doesn't have is logged and the shipped line kept

## When something's wrong

- Not sure the host is right: `bin/moonpool diag verify-fresh` checks each stage from Steam to the hosted save
- No session: `bin/moonpool status` then `bin/moonpool logs game`
- Join Game is missing: check in the viewer that Steam is signed in and on the right branch
- A player connects and drops: compare branch and build then `bin/moonpool logs join_watch`
- The game won't install: `bin/moonpool diag screenshot shot.png`

Known gaps: `Warp` is refused by this build so there's no way to move a player. The hold during the launch cinematic hasn't been proven

## Diagnostic switches

These stay out of `.env.example` because the defaults are what works. Set one in `.env` only to rule something out, then recreate the host

| Setting | Default | What it does |
|---|---|---|
| `GAME_APP_ID` | `1962700` | Steam app id of Subnautica 2 |
| `NULLRHI_ARGS` | `-nullrhi -unattended -log` | Engine arguments; `-nullrhi` is added back if missing (no GPU) |
| `UE4SS_AT_START` | `true` | UE4SS loads at process start through its `dwmapi.dll` proxy |
| `UE4SS_TAG` | `experimental-latest` | The upstream release tag the pinned loader is fetched from |
| `NATIVE_MSVC` | `1` | Microsoft's C++ runtime for the game process only |
| `HOST_PRUNE` | `true` | Takes the host account out of the player list |
| `HIDE_HOST_BODY` | `true` | Hides the host account's body in the world |
| `CLIPBOARD_BRIDGE` | `true` | Copy and paste through the viewer's clipboard panel |
| `S6_SERVICES_GRACETIME` | `210000` | Milliseconds the services get to stop: warning plus save wait plus 30 s |
| `S6_KILL_GRACETIME` | `5000` | Milliseconds before leftover processes are killed |
