# In-game admin

Orders from inside the game pass one gate on the server. The server's own shell needs none:

```mermaid
flowchart LR
  sig["Rename a PDA signal<br/>!kick, !mp g copper 10"] --> gate
  panel["Admin panel (F2) or any<br/>client sending cheat lines"] --> gate
  gate{"sender in ADMINS,<br/>command not denied?"}
  gate -- yes --> run(["runs on the server"])
  gate -- no --> drop(["dropped and logged"])
  shell["bin/moonpool<br/>on the server"] --> run
```

## Who is an admin

Admins are listed by Epic ID, the `eos=` value the UE4SS log prints as each player joins (`player NAME eos=...`):

| Where | Read |
|---|---|
| `ADMINS` in `.env` | at start |
| `control/admins.txt` in the data volume | while running; one per line, text after a space is a note, `#` starts a comment |

Names and Steam IDs don't count, because a client can claim those.

**Moderators** are listed the same way in `control/moderators.txt` (read while running).
- **What they may send:** only console lines led by the console's word (`mp who`) whose command is in `moderator_commands` in `console.json`. As shipped that's `who`, `find`, `list`, `cheats` and `help`.
- **What they may not:** game cheat lines and anything else, which the server drops as it does for any player.
- PDA signal orders stay with admins.

## Orders through a PDA signal

Nothing to install: rename any PDA signal to a command.

- The answer comes back in the signal's name (about 40 characters show): green for done, red for refused. It also shows as a notification on the sender's screen.
- A signal renamed by a non-admin is ignored without a reply.

```
!help                 the list
!kick NAME            remove a player
!time 12:00           set the clock
!weather DA_Storm     set the weather
!slots 8              change the player cap
!ping                 where everyone is, for admins; your own spot for anyone
!cmd LINE             one of the game's console commands, run on the host as you
!mp LINE              the admin console; any other word goes there too, so !give copper 10 works
```

`!cmd` and `!mp` need [console commands](#console-commands) turned on.

## The admin console (`!mp`)

`!mp` takes any console line, plus named commands (`give`, `heal`, `who`...) that look names up. The `mp` can be left out unless the line starts with one of the fixed orders above (`!help`, `!time`...). A named command takes the player first, as on most game servers:

| Signal | Does |
|---|---|
| `!give copper wire 10` | gives you the item with that name, 10 of it |
| `!give john copper 5` | gives it to the player whose name starts with john |
| `!give everyone copper` | gives it to every player (`all` works too) |
| `!give 10 titanium ingot` | the name's words and the number in any order, no quotes needed |
| `!give cop` | an unclear name asks: `cop? 1 Copper  2 Copper Ingot  3 Copper Wire` |
| `!2` | ...and a bare number answers it |
| `!heal`, `!heal john`, `!heal all` | health, oxygen, food and water to 100 for you, a player, or everyone |
| `!@john LINE` | any line, run as that player (`@all`, `@host`, `@me`) |
| `!find titan` | items, players and tags by name, with their ids |
| `!list items cop` | one kind, filtered; `!list commands` lists the game's console commands |
| `!cheats` | which cheat tags named in `console.json` are on |
| `!who` | who is on, with their Epic ID and ping |
| `!SomeConsoleCommand 3` | any other line goes to the game as typed |

- A word after `give` counts as a player only when it starts exactly one player's name and the item's name follows it. Otherwise it's part of the item: `!give titanium ingot` gives the ingot even with a player called Titan on. `@` always means a player.
- A named command with a missing part answers with how it's typed: `use: give [player] <item> [count]`.

Words, commands and replies come from `console.json` (shipped: `mod/MoonpoolHost/console.json`). To change them, put a file with only your changed keys in the data volume and recreate the host:

| Key type | In your file |
|---|---|
| objects, such as `commands` | merge with the shipped ones |
| lists, such as `deny` | replace them |

```json
{
  "commands": {
    "full": { "aliases": ["full"], "lines": ["HealMe", "attr oxygen 100"] }
  }
}
```

- `commands` maps a word to console lines. Arguments are looked up by kind; see `give` in the shipped file.
- `on_ambiguous: first` takes the best match without asking.
- `deny` blocks commands that crash or wipe the world, the engine's `DestroyAll`, `DestroyAllPawnsExceptTarget` and `DestroyPawns` among them. `"deny": []` in your own file turns that off.
- Every line runs as one command. The game's console splits a line at `|` and at line breaks, so a line to run with `|`, `;`, a backtick or a control character is refused on every path (`!mp`, `!cmd`, the cheat panel, `ExecuteForAll`). `!cmd` lines are also capped at 128 characters, as `moonpool diag console` lines are.
- `line_gap_ms` (1000) spaces the lines of one order; each can stall the server a second or so.

| Word | Does | Watch out |
|---|---|---|
| `normal` | `DayOnly 0`, then `RemoveGlobalTag` for each tag in `tags`. On the current build every cheat, god mode and invisibility included, is a world tag, so this clears it for everyone | can't undo `FastSwim` (only on the admin's PC; run it again) or `QuickNav`'s fog and speed (the game's `NormalNav`) |
| `god`, `fastbuild` (the game's own) | toggle | ignore a number: `FastBuild 0` turns it on |
| `tag`, `untag` | add or remove a world tag with the `Global` commands | the game's own `AddTag` and `RemoveTag` act on one player and leave the world's cheat on |
| `undo` | removes the nearest thing within `undo.within_m` metres of the admin, of the class their last spawn placed, and says how far away it was | goes by class and distance, so it may remove a copy someone else placed. The last `undo.keep` per admin are kept until restart |

## Macros

The game's macros are text files in `Content/Macros` on each admin's PC, one console line per row. The cheat panel's Macro button lists them; `RunMacro <name>` runs one. The host checks each line. On the current build:

| Macro | What it does | Undo |
|---|---|---|
| Base Pack, Equipment Pack, Starting Items | gives or equips items (Starting Items' `OxygenTankSmall` isn't found) | nothing to undo |
| QuickNav | no fog, speed 10, fast swim on this PC; day, frozen at noon, for the world | the game's `NormalNav` |
| Superman | `god`, `fastbuild 1`, `unlockall`, `invisible` (toggles: a cheat already on turns off), fast swim | `normal`; `FastSwim` again for swimming |
| SculptDebug | habitat builder, then the toggles `god`, `freebuild`, `unlimitedpower` | `normal` |
| SculptDebugNoSupports | SculptDebug, then `BaseToggleSupportCheck` | `normal`, and `BaseToggleSupportCheck` once more; the host can't tell whether it's on |
| damagedebug | four `giveability` lines | nothing: the game can't find them |

## What admins ran

Every admin line the server handles gets one JSON line in `logs/admin-audit.log` in the data volume:
- **When it's written:** a line typed or picked in game, a console line, a PDA signal order, and a cheat line from a non-admin that the gate refused.
- **What each line holds:** the time (UTC), the sender's name and EOS id, the line, and what came of it (`ran`, `refused: …`, `dropped: …`) with the server's answer.
- **Reading it:** `bin/moonpool logs admin-audit`.
- **Kept:** like the other logs (10 MB plus four older pieces), and it moves with `server pack`.

## Limits

Each console command can stall the server a second or two, so they're queued:

| Queue | Rate | Waiting |
|---|---|---|
| Cheat lines from an admin's game (typed, picked, macro lines) | one per `cheat_gap_s` (1 s, `console.json`), at most one per mod poll (2 s) | `cheat_per_sender` (12) per admin |
| Signal orders and console lines | one per 3 s per admin; one per `admin_gap_s` (10 s, the mod's `config.json`) in all | 3 per admin, 20 in all, then Busy |

Run big batches when nobody's on.

## The game's cheat panel and who it obeys

The game runs a cheat line from any client without checking who sent it. It has no way to open its cheat panel, but a client mod can, so the host mod gates every line:

- From someone in `ADMINS`, the line runs unless `deny` names it, and only with console commands turned on. From anyone else it's dropped and logged as `cheat gate: dropped`.
- `ExecuteForAll` asks the host to relay a line to every player's game. The host relays it only from an admin and only if `deny` doesn't name the command.
- If the host can't stop a line, or can't tell whether it did, it counts as not stopped: the line may run and can't be called back. The log says `cheat gate: COULD NOT STOP` and a non-admin sender is removed (`on_gate_failure`; `log` only logs). The same goes for a relay it couldn't block.
- The server makes no Host call until both gate hooks are in place, and doesn't host at all if the part of the mod that holds them fails to load. The log says `HOLD: the cheat gate is not in place`. `CHEAT_GATE=off` hosts without it ([diagnostic switches](operating.md#diagnostic-switches)).
- `deny` reads the first word of a one-command line, so it lists `ExecuteForAll` and `RunMacro`. A macro picked in the panel still works: its lines arrive one at a time and each is checked.

- A line starting with `signal_word` (`mp`) is a console line: `mp give copper 10` equals `!give copper 10` in a signal. An answer (`who`, `find`, a usage reply, a refusal) shows as a notification on the sender's screen only, for `reply_seconds` (8). A line that only runs, such as `give glass 10`, shows no card: the game's own result is the answer (`reply_on_run: true` brings the card back). Signal orders always answer in the signal's name.
- A typed named command needs no `mp`: `give 10 glass`, `heal all` and `!give john copper 5` get the same name lookup. A line that already names exact ids, as the panel's own picks do (`Give DA_Glass_ItemType 10`), runs as it is.
- A line for a player whose character isn't in the world yet is skipped.

Not yet tested with a second player:

- the `ExecuteForAll` relay check (with one player the game runs it on that player's PC and never asks the host)
- removing a sender after a line that couldn't be stopped
- skipping a player who isn't in the world yet

## The admin panel (MoonpoolConsole)

- Ships with Moonpool in `client-mods/MoonpoolConsole`. Players get it only if `plugins.yaml` lists it with `install: {type: local}`; a folder of the same name under `client-mods/` in the data volume replaces it.
- It grants nothing: the server's gate decides, so non-admins get nothing from it.
- F2 opens one search over everything an admin can run, in a panel of its own built inside the game's cheat panel (whose own parts are hidden, so the game's menu handling still applies):

| Tab | Rows | What a row sends |
|---|---|---|
| Items | the game's items, one row each, the data name under the display name | Give (`Item <id> <count>`), Spawn (`Spawn <id> <count>`), Equip (`Equip <id>`, only where the game calls the item equippable) |
| Server | the server's console commands, from its own `console.json` | `mp <command> <arguments>` |
| Game | the game's console commands, read from the player's cheat manager | the command as written |
| Macros | the game's macros (`Content/Macros` on the admin's PC) | `RunMacro <name>`, run on the admin's PC, which sends the macro's lines one by one; the server checks each |
| Mine | the admin's own rows (below) | their own lines |
| Recent | the lines run from the panel, newest first | the line again, and Undo where one is known |

| Key | Does |
|---|---|
| typing | searches: a row shows if it has every typed word, in its name, data name or category. A number at the end is the count: `glass 10` |
| Up, Down, PgUp, PgDn, mouse wheel | move the choice, one row or a page |
| Enter, or a second click on a row | sends the chosen action at once, or, with nothing matching, the line as typed |
| Tab | puts the exact line the action would send in the search field to change first (`Item DA_Gold_ItemType 1` to `... 10`); a server command stops where its argument goes (`mp give `) |
| Ctrl+Left, Ctrl+Right, or a click | picks the row's action (Give, Spawn, Equip) |
| Alt+1 to Alt+7, or a click | shows that tab |
| Esc, F2 | closes the panel |

- Under the list: the chosen command's signature (`Give  <ItemName: text>  <Amount: number>`, `mp give  <item: items>  [count = 1]`) and the line Enter sends.
- After a line is sent, the panel shows it and, for a server command, the server's answer, as the game's notification also does.
- Undo, from Recent: a spawn by `mp undo`, a tag by its untag, `DayOnly 1` by `DayOnly 0`, `FreezeTime` by `UnfreezeTime`, a toggle (God, Fly, NoClip, …) by running it again. The rules are `opposites` in `config.lua`. A given item has no undo.
- Unpublished items, items in the game's `Deprecated` folder, and items named `[DEPRECATED…]`, `[PLACEHOLDER…]`, `[PH]` or `[TEST…]` are hidden unless `items.show_unpublished` is set.
- Known gap: the panel offers Give for things the game only spawns (vehicles, base pieces, posters); the game answers "Item type … was not found", and Spawn works.
- The lines run are kept in `%LOCALAPPDATA%\Moonpool\console-recent.txt` (removed with the launcher).

**Changing it**

- `Scripts/config.lua` holds every setting: keys, tabs, item actions, undo rules, macros, colours, sizes, words, and the game names the mod relies on.
- Each player can change any of them in `%LOCALAPPDATA%\Moonpool\console-settings.lua`, a file that returns only the keys to change, for example `return { key = 'F3', layout = { top = 0.1 } }`.
- Each player can add rows in `%LOCALAPPDATA%\Moonpool\console-commands.lua`, shown under Mine:

```lua
return {
  { name = 'Daylight', line = 'DayOnly 1' },
  { name = 'Night shift', args = { { name = 'hour', default = '22' } },
    actions = { { label = 'Start', line = 'SetTimeOfDay {hour}' }, { label = 'Stop', line = 'UnfreezeTime' } } },
}
```

- Both files are read with no Lua libraries, so they can hold values only.
- Commands for every admin on a server go in the server's `console.json`: when the server publishes the panel it writes its commands into the mod (`Scripts/host-commands.lua`), so they show under Server with their arguments.

## Console commands

Off by default. To turn them on, add to `enabled_commands` in the host mod's settings file, `sn2headless.json` in the data volume, (keep the other commands you use), then recreate the host:

| Add | Turns on |
|---|---|
| `player` | `bin/moonpool diag console`, `!cmd`, `!mp` and the admin panel's lines |
| `settings` | `world time`, `world weather` |
