# Moonpool

Run a Subnautica 2 server in Docker with nobody at the keyboard

It runs the real Windows game under Wine on your own Steam account and hosts a world for people you let in. No GPU needed

Unofficial. Not affiliated with Unknown Worlds, KRAFTON or Valve. There are no game files in this repo and nothing here is for sale

## What you need

- A Linux box or Docker Desktop with Docker Engine 26 and Compose 2.25 or newer
- About 4 cores 8 GB of memory and 40 GB of SSD for 4 players. That's the game's own limit and the default. You can raise `PLAYER_SLOTS` but it's less proven
- A copy of the game on a Steam account you only use for hosting. An account can only be signed in one place so it can't be the one you play on
- Your friends need their own copy of the game on Steam or Xbox

## Start it

Run these in a terminal on the machine that will host the server

```sh
git clone --branch v0.2.4 --depth 1 https://github.com/moonpool-server/moonpool.git && cd moonpool
cp .env.example .env
docker compose up -d --build
```

Open `http://127.0.0.1:8080/vnc.html` and sign in to Steam once. From another machine tunnel it first with `ssh -L 8080:127.0.0.1:8080 you@server`

The game downloads and the world comes up on its own. That can take a while and the log shows how far along it is

```sh
docker compose logs -f sn2
docker compose ps
```

It's ready when `ps` says healthy. Invite each friend with `bin/moonpool players invite <their steamid64 or profile link>`. They send the hosting account a Steam friend request and it's accepted within a minute. Then they hit Join Game or use the page at `http://<server>:8081/join`

Anyone already friends with the hosting account can join too, so use a fresh account or remove them. Want anyone who finds the account to get in? Set `ALLOWLIST_ONLY=false`

The Discord card and the join page, as players see them

![The Discord card: two worlds, who is on, the codes to add and a Join button](docs/images/discord-card.png)

![The join page: one button that opens the game through Steam](docs/images/join-page.png)

## What's exposed

- Port 8081 serves the join page and the signed mod list on every interface by default because players without a tunnel need it. It shows the host account's Steam id and the current lobby id, which Steam shows the host's friends anyway. `MODS_BIND=127.0.0.1` closes it when you use the tunnel
- With `WEB_MAP=true` the map page shows explored areas and base positions to anyone with the link
- The viewer on 8080 controls the signed-in Steam so it listens on this machine only unless you set `VIEWER_BIND` and a password
- The data volume holds the hosting account's Steam session. Keep it and your backups private

## What you get

- Hosts by itself and comes back after a restart
- More than one world on a machine with `bin/moonpool-instance add`
- Admin from the shell with `bin/moonpool`
- Admin in game by naming a PDA signal `!help`
- Backups you can restore with one command
- A Discord card showing who is on with a join button
- An optional map that charts where players have been
- A clock that holds while the world is empty

## Mods

Your mod list lives inside the server's data volume. Copy [plugins.example.yaml](plugins.example.yaml) in and edit it there

```sh
docker compose exec -T sn2 sh -c 'cat > /home/container/control/plugins.yaml' < plugins.example.yaml
docker compose exec sn2 vi /home/container/control/plugins.yaml
```

Your join page then offers Play with mods

Players install our launcher once from this repo. It shows them what your server wants and asks before installing anything and asks again when that changes. It keeps them on your versions from then on

Mods run with the player's Windows rights and nobody here reviews them so only say yes to a host you trust. The launcher asks Windows Defender to scan each download when Defender is available but a clean scan doesn't prove a mod is safe. A saved yes stays until the list changes. A new key at the same address counts as a new server and warns you

The launcher comes only from this repo's releases. Setup and every update check its signature and the private key isn't on GitHub. It has no Windows code signing so Windows may warn about it. You can also check a copy against its release

```sh
gh attestation verify moonpool.ps1 --repo moonpool-server/moonpool --signer-workflow moonpool-server/moonpool/.github/workflows/ci.yml
```

## Does it work

Tested by hand with real players joining over the internet on Docker Engine and Docker Desktop, on public build `25400633`. CI runs the code's own tests but not the real game

A game update can break it. If that happens the host says so and the [guide](docs/operating.md) covers what to do. Moonpool supports the game's public branch. Other branches need files for their exact build that this project doesn't ship

## More

- [Running Moonpool](docs/operating.md) for sizing, mods, backups and troubleshooting
- Settings are in [.env.example](.env.example) and commands in `bin/moonpool help`

## Questions and security

CONTACT: [issues](https://github.com/moonpool-server/moonpool/issues) for questions and project concerns and [private reporting](https://github.com/moonpool-server/moonpool/security/advisories/new) for security problems. Rights holders can use issues for takedown requests

## Contributing

Issues and pull requests are welcome. `pre-commit run --all-files` runs the same checks as CI. Please don't commit game files, Steam sessions, logs or anything generated from the game

## Legal and risk

Moonpool's own code is MIT licensed so you can reuse it. That licence covers only this code. The game and Steam have their own terms and MIT can't change those

This is unofficial and not affiliated with Unknown Worlds, KRAFTON or Valve. Owning the game doesn't override the game's or Steam's terms and nothing here changes that. Read both sets of terms before you run it

The [Subnautica 2 EULA](https://store.steampowered.com/eula/1962700_eula_0) is with KRAFTON. It limits the game to personal non-commercial use. It bars modifying the game and using it with unauthorized software, bots or scripts and it says breaking its terms can end your licence. Moonpool loads a mod into the game so running it goes against those terms as written

The [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/) applies too. Without Valve's written consent section 2.G restricts modifying Steam content, and hosting or matchmaking through emulation, tunneling, added components or similar tools. Section 4.B restricts tampering with how Steam content runs. Section 4.C restricts scripts and bots that interact with Steam content. An unattended host and automatic friend accepting sit close to those rules and this project has no consent from Valve

Unknown Worlds doesn't officially support mods yet. KRAFTON, Unknown Worlds or Valve could act against this project or the hosting account. Use a spare account you can afford to lose and decide for yourself. This isn't legal advice

We try to stay out of the studio's way. Moonpool ships no game files, no data taken from them and none of the game's art. Its code does name objects in the game so it can call them. It has no item spawning or teleport commands. It hosts four players by default, the game's own limit. If something breaks take mods out and check the game alone before you report anything to Unknown Worlds, and report Moonpool problems here

If Unknown Worlds or KRAFTON ask us to change or stop something we'll do it. If an official dedicated server covers what this does we'll point people to it

This project doesn't sell hosting and asks you not to. That's a stance and a way to reduce that risk, not a limit in the licence

Don't share or rent accounts. [NOTICE](NOTICE) says what older releases contained and how to ask for removal

Parts come from [BeaconServer](https://github.com/HumanGenome/BeaconServer) and other projects listed in NOTICE
