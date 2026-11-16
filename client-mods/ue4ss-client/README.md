# Files for players' UE4SS loader

Copy `Mods/` to `ue4ss-client/Mods/` in the data volume; the server then serves the pinned loader with these files in it ([mods](../../docs/mods.md#players-loader-on-experimental-builds)).

| File | From | Changed |
|---|---|---|
| `Mods/shared/UEHelpers/UEHelpers.lua` | UE4SS v3.0.1-1190-gf673aac0, MIT licence, © the UE4SS team ([github.com/UE4SS-RE/RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)) | `addCallFallback`: when a function looked up by name on an object throws, it is found along the class chain and called through the function object. `GetPlayerController`: its check runs in `pcall`, and when that throws, the game's only player controller is the local one. |

Why: on Subnautica 2 experimental build 0.1.2.0-138154, calling a game function by name (`pawn:K2_GetActorLocation()`) throws `Array failed invariants check`, while calling the same function object (`pawn:CallFunction(fn)`) works. Mods built on these helpers, such as Simple Minimap, then never find the player.
