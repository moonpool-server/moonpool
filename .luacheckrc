-- luacheck configuration for the UE4SS Lua mods and signature scripts.
std = "lua54"
max_line_length = 120

-- Globals UE4SS provides to mods (see the UE4SS Lua API documentation).
read_globals = {
    "RegisterHook", "NotifyOnNewObject", "FindFirstOf", "FindAllOf", "FindObject",
    "StaticFindObject", "ExecuteInGameThread", "ExecuteInGameThreadWithDelay",
    "LoopInGameThreadWithDelay", "CancelDelayedAction",
    "RegisterKeyBind", "RegisterConsoleCommandHandler", "RegisterCustomEvent",
    "IterateGameDirectories", "Key", "ModifierKey", "UEHelpers", "FName", "FText", "FLinearColor",
    "EObjectFlags", "StaticConstructObject", "ForEachUObject",
}
globals = { "LoopAsync", "ExecuteWithDelay" }

-- SN2SlotFreeHost's main.lua is the working host's own file, kept as it ran: its
-- hook callbacks name every argument of the hooked function, and it uses the
-- loader's LoadAsset global.
files["mod/SN2SlotFreeHost/Scripts/main.lua"] = {
    read_globals = { "LoadAsset" },
    unused_args = false,
    max_line_length = false,
}
-- The load test stubs os.getenv to pass the container's environment in.
files["tests/lua/host_mod_spec.lua"] = { globals = { "os" } }
files["tests/lua/host_behaviour_spec.lua"] = { globals = { "os" } }
