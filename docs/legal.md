# Legal and risk

Moonpool's code is MIT licensed. That covers this code only, not Subnautica 2 or Steam. Not legal advice.

## The terms it runs against

- The [Subnautica 2 EULA](https://store.steampowered.com/eula/1962700_eula_0) limits the game to personal, non-commercial use and bars modifying it or using it with unauthorized software, bots or scripts; breaking it can end your licence. Moonpool loads a mod and automates hosting, so running it appears to conflict with those terms.
- The [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/) section 2.G restricts modifying Steam content and hosting through emulation, tunneling or added components without Valve's written consent; 4.B restricts tampering with how Steam content runs; 4.C restricts scripts and bots that interact with it.
- Unknown Worlds, KRAFTON and Valve haven't consented to this project, and Unknown Worlds doesn't officially support mods yet. The hosting account could lose the game or face action on Steam. Host on an account you can afford to lose.

## What Moonpool ships and does

- The repository ships no game files. Its one image from the game is `docs/images/admin-panel.png`, a tight crop of the game's cheat panel as the admin panel mod shows it. Its code names game objects so it can call them.
- Its own commands don't spawn items or move players. The `friends` preset runs the game's `Unlock` command as each joining player so everyone shares the host's base-piece, tool and blueprint unlocks (`PRESET=stock` turns it off). In-game admins can run other console commands only if you enable it.
- Layout files a host puts in `ue4ss-client/` are measured from the game and served to anyone who can reach its join page ([mods](mods.md#players-loader-on-experimental-builds)).

## Reporting

If something breaks, test the game without mods before reporting to Unknown Worlds; report Moonpool problems [here](https://github.com/moonpool-server/moonpool/issues). Rights holders wanting a takedown can open an issue asking for a private contact.

Please don't sell hosting or share or rent accounts.
