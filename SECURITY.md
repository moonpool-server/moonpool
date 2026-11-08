# Security

Report a security problem privately at https://github.com/moonpool-server/moonpool/security/advisories/new and not in a public issue

Say what you found and how to see it

Fixes go into the next release and older releases get none. One person reads these so expect days not hours and no promised date

## What to expect from it

- **One user, no capabilities.** Steam, the game, UE4SS and the host's own mods all run in the game container as one unprivileged user with every Linux capability dropped. A server mod can read anything that user can, so only install mods you trust.
- **The data volume is the secret.** It holds the hosting account's Steam sign-in, the key that signs this server's mod list (`mod-signing/private.pem`) and the viewer password. Anyone with the volume can sign in as the hosting account. Never use your own Steam account as the host.
- **Secrets in `.env`.** The tunnel token goes to the tunnel container only. `DISCORD_WEBHOOK_URL` and `CURSEFORGE_API_KEY` reach the game container, because it posts the card and publishes the mods.
- **What listens.** The viewer (8080) listens on this machine only unless `VIEWER_BIND` says otherwise, and always has a password. Port 8081 is public on purpose: it serves one folder of static files (the join page, the signed mod list, the mod files and, when turned on, the map and the card) and runs no code for a request.
- **Who it talks to.** Steam, always. With `AUTO_ACCEPT_FRIENDS=1`, also Steam's community site as the hosting account. Cloudflare, if a tunnel is on. Discord, if a webhook is set. GitHub, for the pinned UE4SS. GitHub, CurseForge or Nexus Mods, for the mods you list, and the other servers you list in `DISCORD_BOARD_PEERS`. Nothing reports home.
- **Two keys, two promises.** The release key signs the launcher and setup in this repo's releases, and that key is not on GitHub. Each server's own key signs that server's mod list, so a player's launcher knows the list came from the server they said yes to. That does not mean anyone reviewed the mods.
