# Security

Report a security problem privately at https://github.com/moonpool-server/moonpool/security/advisories/new and not in a public issue

Say what you found and how to see it

Fixes go into the next release and older releases get none. One person reads these so expect days not hours and no promised date

## What to expect from it

- **How a player's launcher is trusted.**
  1. The source is in this repository. The CI workflow in `.github/workflows/ci.yml` builds it and attaches a GitHub build attestation to `moonpool-setup.cmd`, `moonpool.ps1` and `moonpool-SHA256SUMS.txt`.
  2. The maintainer signs `moonpool.ps1` on their own machine, with a key kept off GitHub, and publishes the release.
  3. Setup downloads the launcher and its signature from this repository's latest release and checks the signature with the public key it carries before running the launcher. The launcher does the same on every update.
  4. On a player's first join the launcher saves the server's key from its `moonpool.json`. A different key at the same address counts as a new server, and the player is asked before any mod is installed.
  5. Each mod archive is checked against the hash the signed list gives for it (sha256, or the sha1 or md5 that CurseForge publishes) before it is unpacked. Every file placed is recorded with its sha256 and checked again on later runs.
- **What the launcher touches on Windows.** It runs as the signed-in user and never asks for administrator rights.
  - It writes its own folder `%LOCALAPPDATA%\Moonpool` (the launcher, the ledger of files it placed, one folder per server).
  - It writes the registry key `HKCU\Software\Classes\moonpool`, so `moonpool:` links open it.
  - It writes shortcuts named `Subnautica 2 (...)` on the Desktop and in the Start menu.
  - Inside the game's install it writes `Subnautica2\Binaries\Win64` (the loader `dwmapi.dll` and the `ue4ss` folder) and `Subnautica2\Content\Paks\~mods`. While Moonpool's mods are on, it moves a `UE4SS_Signatures` folder the server didn't send aside, and puts it back when they go off.
  - For each session it adds two settings to the game's `Subnautica2\Saved\Config\Windows\Engine.ini`, marked as its own, and takes them out when the mods go off.
  - Downloads and setup go through `%TEMP%`.
  - To find the game it reads `HKCU\Software\Valve\Steam` and Steam's `libraryfolders.vdf` and `appmanifest` files.
  - `-Uninstall` removes the game files it placed that are still as it placed them, the handler and shortcuts that still point at it, and the whole `%LOCALAPPDATA%\Moonpool` folder. It leaves what setup put in `%TEMP%`, and the copies of the player's own files it replaced after asking, in `%LOCALAPPDATA%\Moonpool-replaced`.

- **One user, no capabilities.** Steam, the game, UE4SS and the host's own mods all run in the game container as one unprivileged user with every Linux capability dropped. A server mod can read anything that user can, so only install mods you trust.
- **The volumes are the secret.** The data volume holds the hosting account's Steam sign-in and the viewer password. The key that signs this server's mod list has a volume of its own, mounted at `mod-signing/` in the container, so the data volume can be wiped or rebuilt without players' launchers seeing a new server. Both are mounted in the game container, so anything running there can read both. Anyone with the data volume can sign in as the hosting account. Never use your own Steam account as the host.
- **Secrets in `.env`.** The tunnel token is blanked in the game container and removed before anything in it starts. `DISCORD_WEBHOOK_URL` and `CURSEFORGE_API_KEY` reach the game container, because it posts the card and publishes the mods. The Steam client and the game, and so any mod the game loads, are started with those two, `GITHUB_TOKEN`, `VNC_PASSWORD` and `STEAM_BRANCH_PASSWORD` taken out of their environment; the container's other services still have them. That keeps them out of the game's crash dumps and child processes, not out of a mod's reach: every service runs as the same user, so a mod the host runs (UE4SS Lua can run programs) can read the volume, including the Steam session and the mod-signing key, and the other services' environment. Only run host mods you trust.
- **Backups.** The backup container runs as its upstream image's default user, root, and sees the save staging folder read-only and the backups folder; it reads `backup.env` and only the `BACKUP_*` values compose passes it, never `.env` as a whole, and gets no Steam session.
- **The map** (`WEB_MAP=true`) is public data: `map.json` holds everything the page draws. The fog is a view, not a lock. `MAP_PLAYERS=false` leaves out players and where anyone has been, `MAP_SIGNALS=false` the names and positions of the PDA signals everyone in the game can see.
- **What listens.** The viewer (8080) listens on this machine only unless `VIEWER_BIND` says otherwise, and always has a password. Port 8081 is public on purpose: it serves one folder of static files (the join page, the signed mod list, the mod files and, when turned on, the map and the card) and runs no code for a request.
- **The Steam web session.** `scripts/friend-accept.py` reads two cookies, `sessionid` and `steamLoginSecure`, from the Steam client's cookie store in the volume and sends them only to `steamcommunity.com`, fixed in the code; the web API token that session hands out goes only to `api.steampowered.com`. Without `AUTO_ACCEPT_FRIENDS=1` it only reads (the lobby id, and the count of waiting friend requests); with it, it also accepts invited players and removes banned ones. It never prints a cookie.
- **Who it talks to.** Moonpool's own code sends nothing to its maintainers. It can't speak for Steam, the game, UE4SS or the mods you add.

  | Destination | From | Why | When |
  |---|---|---|---|
  | Steam | the Steam client and the game | sign-in, game updates, the hosted session | always |
  | `steamcommunity.com`, `api.steampowered.com` | `scripts/friend-accept.py`, as the hosting account | read its own lobby id for the join page | when the game log doesn't carry it (it doesn't on the public branch) |
  | the same | the same | read pending friend requests, and with `SHOW_PLAYER_NAMES=true` those players' profile names | `AUTO_ACCEPT_FRIENDS=0` |
  | the same | the same | accept invited players and remove banned ones from its friends | `AUTO_ACCEPT_FRIENDS=1` |
  | Cloudflare | `cloudflared` | carries the join page and mod files | a tunnel is on |
  | Discord | the game container | posts and edits the card | a webhook is set |
  | GitHub | the game container | the pinned UE4SS archive | installing the loader |
  | Valve's CDN | the game container | `SteamSetup.exe` | first start |
  | Microsoft (`aka.ms`) | the game container | the Visual C++ runtime | when `NATIVE_MSVC` asks for it |
  | GitHub, CurseForge | the game container | the mods you list, and their stars, downloads, dates and authors | publishing mods; stats at most every six hours |
  | the servers in `DISCORD_BOARD_PEERS` | the game container | their status for the card | a peer is set |
  | the map picture addresses you set | the game container, https only | the pictures behind the map and its still | `WEB_MAP=true` with a picture set |
  | cdnjs.cloudflare.com, cdn.jsdelivr.net | the map viewer's browser | the page's scripts and icon font | the map page is opened |
  | the map's tile host | the map viewer's browser | the map tiles | the map page is opened with tiles set |

  Nexus Mods files are never fetched by the server: the host pins them and players download them themselves.
- **If the volume leaks.** Change the hosting account's Steam password and use "Deauthorize all other devices" under Steam Guard in its account settings, so the session the volume holds stops working. Delete `mod-signing/private.pem` and `viewer-password` in the container: the next publish makes a new mod-signing key and the next start a new viewer password, unless `VNC_PASSWORD` in `.env` sets one, which you then change there. Players' launchers then treat the server as a new one and ask again, with a warning that the address had a different key.
- **The UE4SS mirror.** The two archives in the `ue4ss-mirror` release are byte-identical to the same-named assets on UE4SS's own `experimental` release; [NOTICE](NOTICE) lists both SHA-256 values, which are the ones pinned in `scripts/common.sh`. To check: `gh api repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental --jq '.assets[] | .name + " " + .digest'`.
- **History.** The repository's history before v0.4.0 (10 November 2026, four days after it went public) was squashed into one commit and its test releases, v0.2.x and v0.3.x, were removed. From v0.4.0 on, history is kept. Release tags are not signed with a git key; the launcher in each release is signed with the release key and attested by the build.
- **Two keys, two promises.** The release key signs the launcher; the setup file carries its public half and a GitHub build attestation, and is not signed itself. Each server's own key signs that server's mod list, so a player's launcher knows the list came from the server they said yes to. That does not mean anyone reviewed the mods.

## Known vulnerabilities in the image

The game image is Debian trixie plus WineHQ's Wine, and Wine pulls in a few hundred libraries. A scan of it (Grype, in the `Docker build` CI job) lists many High and Critical entries. When this section was last revised, every finding in a scan of the image was in a Debian package that Debian had no fix for (its tracker marked them won't-fix or not fixed yet). That can change with any new Debian advisory, so check the step summary of the latest `Docker build` run for the current High and Critical list. The policy:

- CI fails the build on a Critical finding that has a fix, and prints every High and Critical finding, fixed or not, in that job's step summary, so the full list for each Docker-build run is one click away.
- Before tagging a release the maintainer is expected to read that list and remove what Moonpool does not need; CI does not check that this happened. Node.js went this way: Debian's noVNC package declares a dependency on it, and nothing in the image runs Node (the viewer's files are served by websockify, which is Python), so noVNC is now taken from its own release archive, pinned by sha256, and Node is not installed.
- Pillow, which decodes the map's background pictures from addresses the host sets, comes from its own PyPI wheel (13.0.0, pinned by sha256) rather than Debian's 11.1, whose decoder findings Debian does not patch.
- Exposure to the listed libraries comes from what listens and what is parsed. The listeners are lighttpd on 8081 (published as `MODS_BIND` says, every interface by default), websockify on the viewer port (published at `127.0.0.1` unless `VIEWER_BIND` says otherwise) and x11vnc on the container's loopback only. Moonpool's own Python parses answers from Steam (the friend-request flow), Discord, the listed peer servers, GitHub and CurseForge (the metadata and archives of mods the host publishes, and the stars, downloads, dates and authors the join page shows), the tunnel's metrics endpoint, and the map picture addresses the host set, whose pictures Pillow decodes. Which process loads which of the listed libraries is not recorded here.

If you think a finding matters more than this section says, report it as above.
