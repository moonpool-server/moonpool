# Security

Report a security problem privately at https://github.com/moonpool-server/moonpool/security/advisories/new and not in a public issue

Say what you found and how to see it

Fixes go into the next release and older releases get none. One person reads these so expect days not hours and no promised date

## What to expect from it

- **One user, no capabilities.** Steam, the game, UE4SS and the host's own mods all run in the game container as one unprivileged user with every Linux capability dropped. A server mod can read anything that user can, so only install mods you trust.
- **The data volume is the secret.** It holds the hosting account's Steam sign-in, the key that signs this server's mod list (`mod-signing/private.pem`) and the viewer password. Anyone with the volume can sign in as the hosting account. Never use your own Steam account as the host.
- **Secrets in `.env`.** The tunnel token is blanked in the game container and removed before anything in it starts. `DISCORD_WEBHOOK_URL` and `CURSEFORGE_API_KEY` reach the game container, because it posts the card and publishes the mods.
- **What listens.** The viewer (8080) listens on this machine only unless `VIEWER_BIND` says otherwise, and always has a password. Port 8081 is public on purpose: it serves one folder of static files (the join page, the signed mod list, the mod files and, when turned on, the map and the card) and runs no code for a request.
- **Who it talks to.** Steam, always. Steam's web API with the hosting account's web session, to read its own lobby id for the join page; with `AUTO_ACCEPT_FRIENDS=0`, also to read its pending friend requests (and, with `SHOW_PLAYER_NAMES=true`, those players' profile names); with `AUTO_ACCEPT_FRIENDS=1`, to accept and remove friends as that account. Cloudflare, if a tunnel is on. Discord, if a webhook is set. GitHub, for the pinned UE4SS. GitHub, CurseForge or Nexus Mods, for the mods you list, and the other servers you list in `DISCORD_BOARD_PEERS`. The map page loads its scripts from cdnjs in the viewer's browser, and the server fetches any map picture you set. Moonpool's own code sends nothing to its maintainers; it can't speak for Steam, the game, UE4SS or the mods you add.
- **Two keys, two promises.** The release key signs the launcher; the setup file carries its public half and a GitHub build attestation, and is not signed itself. Each server's own key signs that server's mod list, so a player's launcher knows the list came from the server they said yes to. That does not mean anyone reviewed the mods.
