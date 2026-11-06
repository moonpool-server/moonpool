# Running Moonpool

Settings are explained in `.env.example`. Commands are in `bin/moonpool help`. This covers the rest

## Size

4 players need about 4 cores 8 GB of memory 40 GB of SSD and 10 Mbit upload. Measured at 2 players it used 2.3 cores and 6 GB

8 players is a guess at 6 cores 12 GB 60 GB and 25 Mbit. `metrics.csv` in the data volume shows what your host really uses

## Signing in

The viewer controls a signed in Steam so keep it off the internet. Use an SSH tunnel or Tailscale to reach it because they're stronger than a VNC password. If you bind it to your LAN with `VIEWER_BIND=0.0.0.0` it won't start without `VNC_PASSWORD`

Use the hosting account with Steam Guard on and pick Remember me. To paste open the noVNC side panel and put it in the clipboard there then press Ctrl+V in Steam

Moonpool never sees your password and it's not in `.env`. The sign in stays in the data volume and anything running in the container can use it. To accept friend requests by itself Moonpool reads the Steam client's own web session out of its cookie store in the volume and talks to Steam as that account; `AUTO_ACCEPT_FRIENDS=0` turns that off and you accept requests in the viewer. So use a dedicated account, keep Steam Guard on and keep the volume private

Lost the machine? Deauthorize devices in Steam and change the password. `docker compose down -v` deletes the world and its saves for good

## Joining

There's no port to forward. Invite each player with `bin/moonpool players invite <steamid64 or profile link>`. They send the hosting account a friend request, it's accepted within a minute (`AUTO_ACCEPT_FRIENDS=0` leaves that to you), and they hit Join Game or use the join page. `ALLOWLIST_ONLY=false` lets in anyone who asks. Anyone already friends with the account can join either way until you remove them with `bin/moonpool ban add`. Everyone needs the same `STEAM_BRANCH` and game build

`moonpool ban add` blocks someone for good and `players kick` only removes them for now

## Xbox and Game Pass players

Experimental. They can't be invited through Steam. They add the hosting account by its in-game friend code and join from the game's own friends list. The game makes that code only while its Friends screen is open, so `bin/moonpool diag friend-code` opens that screen the way a click would, reads the code and closes it again. Run it once while nobody is on, or with `--force` while players are. Each run makes a new code, and the last one survives restarts. From then on it shows on the Discord card and in that command. It's marked experimental because it's read off the game's own screen

## Mods

```sh
cp plugins.example.yaml plugins.yaml   # edit it with any editor
bin/moonpool mods publish plugins.yaml
bin/moonpool mods list
```

An entry needs the mod's download link: a GitHub release file, a CurseForge file page or a Nexus file page. CurseForge needs your own API key in `.env` (`CURSEFORGE_API_KEY`, free at console.curseforge.com) and a mod whose author allows distribution; otherwise players download that one from its page

A Nexus file needs `bin/moonpool mods pin "<name>" <file.zip>` once. Players then download it themselves and the launcher checks it matches

A mod that ships `.pak` files instead of Lua needs `kind: pak` on its entry. Everything optional installs by default; a player can leave one out

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
```

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
bin/moonpool server restore backups/<file>.tar.gz Slot1
```

Restore keeps a safety copy of your current saves and then hosts again, about a minute after the command returns. It checks that the archive reads and holds a save, not that the save is undamaged. Tested on an empty world with a real join. Restoring with players on hasn't been tested

Two worlds must not share a `BACKUP_DIR`: they overwrite each other's archives. `bin/moonpool-instance` gives each its own

## Updates

The game updates when the container starts, but only after a save copy works. `UPDATE_WITHOUT_BACKUP=true` skips that check. `AUTO_UPDATE=false` holds it on the build you have. Check nobody's online before you recreate the host

A new build only hosts if the loader works on it. The public branch uses a loader that needs nothing from you. Other branches aren't supported out of the box: they need the older pinned loader plus your own set of files for that exact build, in a folder under `ue4ss-layouts` in the data volume, with `MemberVariableLayout.ini` `VTableLayout.ini` `UE4SS-settings.ini` `UE4SS_Signatures` and the game exe's SHA-256 in `exe.sha256`. This project doesn't ship them or help make them

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

## Map

`WEB_MAP=true` adds a page at `/map` and a Map button on the Discord card. It charts where players have been from the positions the game reports, colored by depth, with bases and lifepods. It shows no names and anything new appears 15 minutes later (`MAP_DELAY_MINUTES`), but anyone with the link can see bases and explored areas

Moonpool ships no map picture. To put one behind the trails, copy a map file into the data volume:

```sh
docker compose cp map-background.example.json sn2:/home/container/map-background.json
```

The file has one entry per game branch, so public and experimental can use different maps. A branch's entry is one picture or a list of pictures laid side by side. Each `url` is tile addresses with `{z}`, a picture's address or a file you put in the data volume. `bounds` are the picture's left, top, right and bottom edges in game units

The experimental build carries its own top-down region pictures in the game folder under `Subnautica2/Content/Debug`, with their bounds in `maps.json` there. They're the studio's own files. Moonpool doesn't ship or fetch them and putting them on a page is between you and the studio

For your own picture pick two spots far apart that you can find in game. Stand on each and run `bin/moonpool map where <player>`, note each spot's pixel position in the picture, then `bin/moonpool map bounds` works out the edges. The picture can't be rotated

The page carries link preview tags and a still at `/map.png`, so a pasted link shows the map in Discord and the like. `/map?embed=1` hides the heading for an iframe. The still is drawn on your host from the same tiles so it's your call too

The example points at [joric's Subnautica 2 tileset](https://github.com/joric/subnautica2_tileset), which your players' browsers load from joric's site. It's a community capture of the game from May 2026, before the experimental branch opened. It needs no lining up but newer builds may differ and no capture made on experimental is known. Its Unlicense covers joric's work and can't speak for the game's own rights, so that part is your call

## When something's wrong

- Not sure the host is right: `bin/moonpool diag verify-fresh` checks each stage from Steam to the hosted save
- No session: `bin/moonpool diag receipt` then `bin/moonpool logs game`
- Join Game is missing: check in the viewer that Steam is signed in and on the right branch
- A player connects and drops: compare branch and build then `bin/moonpool logs join_watch`
- The game won't install: `bin/moonpool diag screenshot shot.png`

Known gaps: `Warp` is refused by this build so there's no way to move a player. The hold during the launch cinematic hasn't been proven
