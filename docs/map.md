# Map

`WEB_MAP=true` adds a live map at `/map`, shows it on the join page and adds a Map button beside Join on the Discord card. Anyone with the link sees it, and can fetch `map.json`, which holds everything the page draws, fogged or not.

## What it shows

| Shows | Leaves out |
|---|---|
| Each player where they were `MAP_DELAY_MINUTES` ago (15; 0 is the last position), coloured by depth, as "Player 1" etc. Names with `MAP_PLAYER_NAMES=true`, never with `SHOW_PLAYER_NAMES=false`. A player who left stays faded for an hour | Bases: the game's base position can be far from its rooms, so name a signal there instead |
| Lifepods and the PDA signals everyone can see. A signal shows once it has stayed put for the delay, so a vehicle's shows where it was left | Signals hidden by default, such as undiscovered story places, and admin commands |
| Fog over places nobody has visited, clearing along each player's route on the same delay, when a map picture is set | Players, explored places and signals that follow something, with `MAP_PLAYERS=false`; signals with `MAP_SIGNALS=false`. Both apply to `map.json` too |

## A map picture

Moonpool ships no map picture. To set one:

```sh
docker compose cp map-background.example.json sn2:/home/container/map-background.json
```

- One entry per branch: a picture, or a list laid side by side. Each `url` is a tile address with `{z}`, a picture address or a file in the data volume. `bounds` are left, top, right, bottom in game units. Name the picture's author and licence in `credit`; the page shows it.
- Your own picture: stand on two far-apart spots and run `bin/moonpool map where <player>` on each, note their pixel positions, then `bin/moonpool map bounds` works out the edges. No rotation.
- The example uses [joric's Subnautica 2 tileset](https://github.com/joric/subnautica2_tileset), loaded by players' browsers from joric's site: a community capture from May 2026, before the experimental branch, so newer builds may not match it. Its Unlicense covers joric's work, not the game's rights.
- The experimental build has region pictures under `Subnautica2/Content/Debug`, bounds in `maps.json`. They're the studio's files; Moonpool doesn't ship or fetch them.

## The page

- Clicking a player follows them and draws the path that page has seen. With player names off, numbers are reassigned when players come and go, so a follow can jump to someone else.
- The address holds the view (`#x=..&y=..&z=..`, `hide=fog,signals`, `follow=<name>`), so a copied link opens the same place.
- `/map.png` is a still for link previews and the Discord card, drawn on your server from the same picture. `/map?embed=1` hides the side panel, for an iframe.
- Pages refresh every `MAP_REFRESH_SECONDS` (60, minimum 10); the server writes every 30 s. With a delay of 0, everyone with the link sees roughly where you are now.
- The page's libraries and icon font load in the viewer's browser from cdnjs.cloudflare.com and cdn.jsdelivr.net (listed in `NOTICE`).
