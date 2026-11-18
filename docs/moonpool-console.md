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
| Up, Down, PgUp, PgDn, mouse wheel | move the choice |
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
- Both run as Lua with no libraries, so they can't open files or run programs.

## On a Moonpool server

A Moonpool server publishes this mod to its players with its own command list written in, which adds:
- a Server tab with the server's console commands;
- the answer to each command shown in the panel;
- items for another player or everyone, run as them by the server.

The server checks every line: only its admins can run anything ([docs/admin.md](admin.md)). Without a Moonpool server the Server tab stays hidden.
