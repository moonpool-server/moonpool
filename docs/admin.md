# In-game admin

## Who is an admin

Admins are listed by Epic ID: `ADMINS` in `.env` (read at start), or `control/admins.txt` in the data volume (one per line, re-read while running; text after a space is a note, `#` starts a comment). The UE4SS log prints `player NAME eos=...` as each player joins. Names and Steam IDs don't count, because a client can claim those.

## Orders through a PDA signal

Nothing to install: rename any PDA signal to a command. The host writes the answer into the signal's name (about 40 characters show), green for done and red for refused, and as a notification on the sender's screen. A signal renamed by a non-admin is ignored without a reply.

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

`!cmd` and `!mp` need [console commands](#console-commands) turned on.

## The admin console (`!mp`)

`!mp` takes any console line, plus shortcuts and name lookups:

```
!mp g cop 10              Give the only item whose name starts with cop, 10 of it
!mp g 10 titanium ingot   the name's words and the number in any order, no quotes needed
!mp g tit                 an unclear name asks: tit? 1 Titanium  2 Titanium Ingot
!mp 2                     ...and a bare number answers it
!mp h                     heal, then oxygen, food and water to 100
!mp @john h               heal the player whose name matches john; @all and @host work too
!mp f titan               find items, players and tags by name, with their ids
!mp l items cop           list one kind, filtered
!mp l commands            the game's console commands, once the host is in the world
!mp c                     which cheat tags named in console.json are on
!mp w                     who is on, with their Epic ID and ping
!mp SomeConsoleCommand 3  any other line goes to the game as typed
!mp .                     the last line again
```

Words, shortcuts and replies come from `console.json` (shipped: `mod/SN2SlotFreeHost/console.json`). To change them, put a file with only your changed keys in the data volume and recreate the host. Objects such as `commands` merge with the shipped ones; lists such as `deny` replace them.

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

`off` (or `normal`) runs `DayOnly 0` and `RemoveGlobalTag` for each tag in `tags`. On the current build every cheat, god mode and invisibility included, is a world tag, so `off` clears it for everyone. It can't undo `FastSwim` (only on the admin's PC; run it again) or `QuickNav`'s fog and speed on the admin's PC (the game's `NormalNav`).

`god` and `fastbuild` toggle and ignore a number (`FastBuild 0` turns it on). The game's `RemoveTag` and `AddTag` act on the player who runs them and leave the world's cheat on; `tag+`, `tag-` and `off` use the `Global` commands.

`undo` (or `u`) removes the nearest thing within `undo.within_m` metres of the admin, of the class their last spawn placed, and says how far away it was. It goes by class and distance, so it may remove a copy someone else placed. The host keeps the last `undo.keep` per admin until restart.

## Macros

The game's macros are text files in `Content/Macros` on each admin's PC, one console line per row, listed by the cheat panel's Macro button or run with `RunMacro <name>`. The host checks each line. On the current build:

| Macro | What it does | Undo |
|---|---|---|
| Base Pack, Equipment Pack, Starting Items | gives or equips items (Starting Items' `OxygenTankSmall` isn't found) | nothing to undo |
| QuickNav | no fog, speed 10, fast swim on this PC; day, frozen at noon, for the world | the game's `NormalNav` |
| Superman | `god`, `fastbuild 1`, `unlockall`, `invisible` (toggles: a cheat already on turns off), fast swim | `off`; `FastSwim` again for swimming |
| SculptDebug | habitat builder, then the toggles `god`, `freebuild`, `unlimitedpower` | `off` |
| SculptDebugNoSupports | SculptDebug, then `BaseToggleSupportCheck` | `off`, and `BaseToggleSupportCheck` once more; the host can't tell whether it's on |
| damagedebug | four `giveability` lines | nothing: the game can't find them |

## Limits

Each console command can stall the server a second or two, so they're queued:

| Queue | Rate | Waiting |
|---|---|---|
| Cheat lines from an admin's game (typed, picked, macro lines) | one per `cheat_gap_s` (1 s, `console.json`), at most one per mod poll (2 s) | `cheat_per_sender` (12) per admin |
| Signal orders and console lines | one per 3 s per admin; one per `admin_gap_s` (10 s, the mod's `config.json`) in all | 3 per admin, 20 in all, then Busy |

Run big batches when nobody's on.

## The game's cheat panel and who it obeys

The game sends a cheat line from any client to the host and runs it without checking the sender. The game has no way to open its cheat panel, but a client mod that shows it can send lines. The host mod gates them:

- From someone in `ADMINS`, the line runs unless `deny` names it, and only with console commands turned on. From anyone else it's dropped and logged as `cheat gate: dropped`.
- `ExecuteForAll` asks the host to relay a line to every player's game. The host relays it only from an admin and only if `deny` doesn't name the command.
- If the host can't stop a line, it runs and can't be called back. The log says `cheat gate: COULD NOT STOP` and a non-admin sender is removed (`on_gate_failure`; `log` only logs).
- `deny` reads the first word, so it lists `ExecuteForAll` and `RunMacro`. A macro picked in the panel still works: its lines arrive one at a time and each is checked.

A line starting with `signal_word` (`mp`) is a console line: `mp g tit 10` equals `!mp g tit 10` in a signal. The answer shows as a notification for `reply_seconds` (8). A line for a player whose character isn't in the world yet is skipped.

Not yet tested with a second player: the `ExecuteForAll` relay check (with one player the game runs it on that player's PC and never asks the host), removing a sender after a line that couldn't be stopped, and skipping a player who isn't in the world yet.

## The admin panel (MoonpoolConsole)

`client-mods/MoonpoolConsole` ships with Moonpool. Players get it only if `plugins.yaml` lists it with `install: {type: local}`; a folder of the same name under `client-mods/` in the data volume replaces it. It grants nothing: the host's gate decides, so non-admins get nothing from it.

- F2 opens the game's cheat panel and pick lists as one palette: tabs (Item, Spawn, Equip, Macro, History), the command line and the open list. F2 again closes everything; Esc steps back one level.
- With a list open, typing filters it. A row shows if it contains every typed word, in the item's name or category (`tools`, `resource`). Up and Down pick a row; Enter runs it and the list stays open.
- With no list open, Enter sends the line to the host: a game command as is (`HealMe`), anything else as a console line (`who`, `g tit 10`).
- Unpublished items are hidden unless `search.show_unpublished` is set.

`Scripts/config.lua` holds every setting: key, console word, position, which parts stay, and the game names the mod relies on.

## Console commands

`bin/moonpool diag console` runs one of the game's console commands as a player. Off by default. To turn it on, add `player` to `enabled_commands` in `sn2headless.json` in the data volume (keep the other commands you use) and recreate the host. `world time` and `world weather` need `settings` there too.
