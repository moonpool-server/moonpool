# Moonpool Console

A UE4SS mod for Subnautica 2: F2 opens one search over the game's items, its console commands and its macros, with the actions each one offers. It is the admin panel that ships with [Moonpool](../README.md), released as a mod of its own. MIT licence.

## What it needs

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) installed for the game.
- Cheats allowed for you: in single player, or on a host that lets you run console cheats. The mod sends the game's own cheat lines; it unlocks nothing the game wouldn't run.

## Install

Unzip `MoonpoolConsole-<version>.zip` into the game's `Subnautica2/Binaries/Win64/ue4ss/Mods`. The folder holds `enabled.txt`, so UE4SS starts it. F2 in the world opens it.

## What it does

| Tab | From the game |
|---|---|
| Items | every item, with Give, Spawn and Equip where the game's own Item, Spawn and Equip lists hold it, sent with those lists' own commands |
| Game | the game's console commands, each with its parameters |
| Macros | the game's own macros |
| Mine | rows you add yourself (below) |
| Recent | lines you ran, with Undo where one is known |

| Key | Does |
|---|---|
| typing | searches; a number at the end is the count (`glass 10`) |
| Up, Down, PgUp, PgDn, or a click on a row | move the choice (the mouse wheel scrolls the list) |
| Enter | sends the chosen action, or the line as typed |
| Tab | puts the exact line in the search field to change first |
| Ctrl+Left, Ctrl+Right | Give, Spawn or Equip |
| Ctrl+Up, Ctrl+Down | who an item is for: you, another player, everyone (needs a Moonpool server, below) |
| Alt+1 to Alt+7 | tabs |
| F1 | all key hints |
| Esc, F2 | close |

## Changing it

- `Scripts/config.lua` holds every setting: keys, tabs, colours, sizes, words.
- Your own changes go in `%LOCALAPPDATA%\Moonpool\console-settings.lua`, a file that returns only the keys to change, for example `return { key = 'F3' }`.
- Your own rows go in `%LOCALAPPDATA%\Moonpool\console-commands.lua`, for example `return { { name = 'Daylight', line = 'DayOnly 1' } }`.
- Both run as Lua with no libraries, so they can't open files or run programs. They can still hold any Lua: one that never finishes holds up the game when the panel first opens, so keep them to plain tables.

## On a Moonpool server

A Moonpool server publishes this mod to its players with its own command list written in, which adds:
- a Server tab with the server's console commands;
- the server's answer to a command, shown in the panel;
- items for another player or everyone, run as them by the server. A line for everyone goes on a second Enter within 5 seconds (`confirm_s`).

What runs where:
- **Checked by the server.** Every line that reaches a Moonpool server: game cheats, the lines a macro sends, server commands. Its cheat gate drops each one from anyone who isn't one of its admins ([docs/admin.md](admin.md)).
- **Not checked by the server.** A row of your own marked `local_run`, which runs in the game's console on your PC only.
- **The command list.** The server's `host-commands.lua` runs as Lua with no libraries, like your own files. The server sends the whole mod, so this file doesn't widen what a server can put on your PC.

Without a Moonpool server the Server tab and the "For" line stay hidden.
