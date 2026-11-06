-- SN2SlotFreeHost: Slot Expansion and Session Host Automation for Subnautica 2
print("[SN2SlotFreeHost] Initializing Dedicated Server Slot-Free Mod...")

-- All Lua runs on the game thread. On UE4SS's async thread it shares one Lua state with the
-- game thread's hooks, which corrupted that state and crashed inside UE4SS.dll (its own docs
-- deprecate LoopAsync; RE-UE4SS issue 168). A loop still ends by returning true.
if LoopInGameThreadWithDelay then
    LoopAsync = function(ms, fn)
        local handle
        handle = LoopInGameThreadWithDelay(ms, function()
            if fn() == true then CancelDelayedAction(handle) end
        end)
    end
    ExecuteWithDelay = ExecuteInGameThreadWithDelay
end

-- Recipe rule: PLAYER_SLOTS real players; the host's own player counts against the
-- limit (measured: GetNumPlayers 2 with one joiner), so the session is hosted at PLAYER_SLOTS + 1.
-- HOST_NAME is the host account's Steam persona, used to find its player.
-- The container exports these (launch-headless.sh); the literals are the original defaults.
local PLAYER_SLOTS = tonumber(os.getenv("SN2_PLAYER_SLOTS") or "") or 4
local HOST_NAME = os.getenv("SN2_HOST_NAME") or "SN2 Host"
-- WORLD_NAME is the Host call's ServerName, which the game writes into the travel options as
-- SaveSlotDisplayName ("?listen?SaveSlotDisplayName=Subnautica2Dedicated?SaveSlotName=Slot1"
-- for ServerName "Subnautica2Dedicated"). '?', '=' and '&' would split that option string: dropped.
local function world_name()
    local n = (os.getenv("SN2_WORLD_NAME") or ""):gsub("[%?=&\"\\%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if n == "" then n = "Subnautica 2 server" end
    return n:sub(1, 64)
end
-- After the world map loads: raise the world GameSession limit, then (optionally) remove the host's
-- own player with GameplayStatics.RemovePlayer so the lifepod's "all active players aboard" check
-- passes. Removing the host's player crashes the game right after launch, so RemovePlayer is gone.
-- HOST_PRUNE (default on): port of BeaconServer v0.3.137 (MIT),
-- read from ue4ss/Mods/BeaconNoPhantomHost/Scripts/main.lua (prune_phantom_player_array:
-- gs.PlayerArray = kept, the host's PlayerState left alive with bIsSpectator/bOnlySpectator/bIsABot set)
-- and ue4ss/Mods/BeaconStoryGoalUnlock/Scripts/main.lua (the three Ch1 lifepod goals unlocked through
-- UWEStoryGoalsWorldSubsystem:UnlockStoryGoal(goal, nil, false) once a real player has a body).
-- The host's controller and local player are kept; RemovePlayer is never called.
-- SN2_HOST_PRUNE=false keeps the host's PlayerState in the array (no spectator/bot flags):
-- on the public build every join crashed the host in the join's own frame,
-- "Join succeeded" then EXCEPTION_ACCESS_VIOLATION reading 0x10), with body hiding off too.
local HOST_PRUNE = (os.getenv("SN2_HOST_PRUNE") or "true") ~= "false"
-- SN2_HIDE_HOST_BODY (default on): the host's own pawn stands in the world (a joined
-- player saw "SN2 Host" with a team marker 405 m away). Once the pawn exists it is hidden and
-- its collision switched off, nothing else: not destroyed, not unpossessed, not moved. Whether
-- the roster entry and the marker go with it is measured from a joined client, not assumed.
local HIDE_HOST_BODY = (os.getenv("SN2_HIDE_HOST_BODY") or "true") ~= "false"
local STORY_GOALS_ENABLED = (os.getenv("SN2_STORY_GOALS") or "true") ~= "false"
local STORY_GOALS = {
    "/Game/Data/Narrative/Dialogue/Chapter_1/Lifepods/DA_StoryGoal_World_Ch1_LifepodInvestigatorAssigned.DA_StoryGoal_World_Ch1_LifepodInvestigatorAssigned",
    "/Game/Data/Narrative/Dialogue/Chapter_1/Lifepods/DA_StoryGoal_World_Ch1_LifepodNoABooted.DA_StoryGoal_World_Ch1_LifepodNoABooted",
    "/Game/Data/Narrative/Dialogue/Chapter_1/Lifepods/DA_StoryGoal_World_Ch1_LifepodsReleased.DA_StoryGoal_World_Ch1_LifepodsReleased",
}
local function ps_name(ps) local n = "?"; pcall(function() n = ps.PlayerNamePrivate:ToString() end); return n end
local function ps_has_pawn(ps) local p = false; pcall(function() local pw = ps.PawnPrivate; p = (pw ~= nil and pw:IsValid()) end); return p end
-- Prune the host's PlayerState from GameState.PlayerArray (Beacon's method). Returns the name of a
-- real player with a body, or nil. Safe to call repeatedly: a no-op when the host is already out.
local function prune_host(PM)
    local gs = FindFirstOf("GameStateBase")
    if not (gs and gs:IsValid()) then return nil end
    local kept, host, real = {}, nil, nil
    for i = 1, #gs.PlayerArray do
        local ps = gs.PlayerArray[i]
        if ps_name(ps) == HOST_NAME then host = ps
        else kept[#kept + 1] = ps; if ps_has_pawn(ps) then real = real or ps_name(ps) end end
    end
    if host and HOST_PRUNE then
        pcall(function() host.bIsSpectator = true end)
        pcall(function() host.bOnlySpectator = true end)
        pcall(function() host.bIsABot = true end)
        local ok, err = pcall(function() gs.PlayerArray = kept end)
        print(PM .. "prune host PlayerState: " .. (ok and "ok" or ("ERR " .. tostring(err))) .. ", PlayerArray count now " .. #gs.PlayerArray)
    end
    return real
end
-- The host's own pawn (see SN2_HIDE_HOST_BODY): hidden, no collision, and no damage.
-- Hunger and thirst in this game are attribute damage on the pawn's health set
-- component (the host log: "Flushing Damage 4.00 ReceivedDamage.Dehydrated", then
-- "has died | Class=UUWEHealthSetComponent"), which the engine's God command does not
-- touch: a joined player saw the host body dying and respawning with a countdown
-- So the component's own SetDamageMultiplier(0) and
-- RestoreHealth are used. With no damage the body never dies, so there is no respawn
-- and no new pawn: this runs ONCE, from the post-map loop, before any player joins.
-- Walking controllers and components while a player joins can hit a half-built object
-- and crash the host, so it never runs later.
local host_body_treated = nil -- object path of the pawn treated
-- Exact reflected fields: Engine.hpp:9563,9582,9586 (Actor), :8820 (Pawn
-- PlayerState), and :11038 (PlayerState inactive) in a function dump.
local function hide_host_pawn(pawn, ps)
    local okh = pcall(function() pawn.bHidden = true end)
    local okc = pcall(function() pawn.bActorEnableCollision = false end)
    local okr = pcall(function() pawn.bReplicates = false end)
    local okp = ps and ps:IsValid() and pcall(function() ps.bReplicates = false end) or false
    if ps and ps:IsValid() then pcall(function() ps.bIsInactive = true end) end
    return okh, okc, okr, okp
end
local function treat_host_body(PM)
    if not HIDE_HOST_BODY then return end
    local pawn, ps
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local n; pcall(function() n = ps_name(pc.PlayerState) end)
        if n == HOST_NAME then pcall(function() pawn = pc.Pawn; ps = pc.PlayerState end) break end
    end
    if not (pawn and pawn:IsValid()) then return end
    local who = "?"; pcall(function() who = pawn:GetFullName() end)
    if host_body_treated then return end
    -- Property writes, not the engine's setter functions: the loader refused
    -- SetActorHiddenInGame with "Array failed invariant" on this build.
    local okh, okc, okr, okp = hide_host_pawn(pawn, ps)
    -- Clients draw the roster entry and the team marker from the host's PlayerState
    -- (its GetTeamMemberViewModel), which they receive whatever the host prunes from
    -- its own PlayerArray (a joined player still saw both). With the
    -- PlayerState and the body no longer replicating, a client never learns of
    -- either: the shape a dedicated server would have.
    -- A client that joined after the host's PlayerState
    -- was marked inactive drew neither the roster entry nor the marker.
    -- The health set component is the one whose outer is this pawn. Every component
    -- is checked alive first: at a join the game crashed (the
    -- loader on the stack inside the tick) twelve seconds after a character began
    -- spawning, which is when this walk can meet a half-built component; a pcall
    -- does not catch a native fault, IsValid avoids it.
    local okd, errd, found = false, "no health component on the pawn", false
    for _, c in ipairs(FindAllOf("UWEHealthSetComponent") or {}) do
        local outer
        if c and c:IsValid() then pcall(function() outer = c:GetOuter():GetFullName() end) end
        if outer == who then
            found = true
            okd, errd = pcall(function() c:SetDamageMultiplier(0.0); c:RestoreHealth() end)
            break
        end
    end
    host_body_treated = require('status').path_of(who)
    print(PM .. "host body: hidden " .. (okh and "ok" or "ERR") .. ", collision off " .. (okc and "ok" or "ERR")
        .. ", damage x0 " .. (okd and "ok" or ("ERR " .. tostring(found and errd or errd)))
        .. ", replication off body " .. (okr and "ok" or "ERR") .. " state " .. (okp and "ok" or "ERR")
        .. " (" .. tostring(who) .. ")")
end
-- Called inside recipe.lua's existing status pass. The path captured above makes this
-- one StaticFindObject plus property reads; it never scans the object array.
_G.SN2_CHECK_HOST_BODY = function(path)
    path = path or host_body_treated
    if not (HIDE_HOST_BODY and path) then return end
    local pawn
    pcall(function() pawn = StaticFindObject(path) end)
    if not (pawn and pawn:IsValid()) then return end
    local hidden = false
    pcall(function() hidden = pawn.bHidden == true end)
    if hidden then return end
    local ps
    pcall(function() ps = pawn.PlayerState end)
    local okh, okc, okr, okp = hide_host_pawn(pawn, ps)
    print("[SN2SlotFreeHost] status: host body visible again; hidden " .. (okh and "ok" or "ERR")
        .. ", collision off " .. (okc and "ok" or "ERR")
        .. ", replication off body " .. (okr and "ok" or "ERR") .. " state " .. (okp and "ok" or "ERR"))
end
-- The host's player ENTRY (roster line and team marker), apart from its body: on the
-- public build the host never gets a body ("SN2 Host (controller yes,
-- body no)" for the whole session), so treat_host_body never ran and a joined
-- player saw "SN2 Host" in the roster. This runs once after hosting, before any
-- join, body or not; a client joining after it draws no entry (measured from the
-- joining client's own log: one team entry where there had been two).
-- SN2_HOST_PRUNE=false leaves the host listed, so it leaves this off too.
local host_state_treated = false
local function treat_host_state(PM)
    if not HOST_PRUNE or host_state_treated then return end
    local ps
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local n; pcall(function() n = ps_name(pc.PlayerState) end)
        if n == HOST_NAME then pcall(function() ps = pc.PlayerState end) break end
    end
    if not (ps and ps:IsValid()) then return end
    local okp = pcall(function() ps.bReplicates = false end)
    local oki = pcall(function() ps.bIsInactive = true end)
    host_state_treated = true
    print(PM .. "host player entry: replication off " .. (okp and "ok" or "ERR")
        .. ", inactive " .. (oki and "ok" or "ERR") .. " (body or not)")
end
local function unlock_story_goals(PM)
    local sub = FindFirstOf("UWEStoryGoalsWorldSubsystem")
    local st = StaticFindObject("/Script/UWEStoryGoals.Default__UWEStoryGoalsStatics")
    if not (sub and sub:IsValid() and st and st:IsValid()) then print(PM .. "story goals: subsystem or statics not found") return end
    for _, path in ipairs(STORY_GOALS) do
        local short = path:match("([^%.]+)$")
        local g = StaticFindObject(path)
        if not (g and g:IsValid()) and type(LoadAsset) == "function" then pcall(function() g = LoadAsset(path) end) end
        if not (g and g:IsValid()) then print(PM .. "goal NOT FOUND " .. short)
        else
            local oku, erru = pcall(function() sub:UnlockStoryGoal(g, nil, false) end)
            local oka, after = pcall(function() return st:IsStoryGoalUnlocked(sub, g, nil) end)
            print(PM .. string.format("goal %s unlock_ok=%s err=%s unlocked=%s", short, tostring(oku), tostring(erru), oka and tostring(after) or "ERR"))
        end
    end
end
local MaxSlots = PLAYER_SLOTS + 1
local hosted = false
-- attempted: the one Host call was made; host_ok: it returned without a Lua error.
-- hosted is set only when both hold AND the session limit reads back as MaxSlots.
local attempted, host_ok = false, false

-- Hook Actor:ReceiveBeginPlay for AGameSession to expand MaxPlayers
RegisterHook("/Script/Engine.Actor:ReceiveBeginPlay", function(Context)
    local Actor = Context:get()
    if Actor and Actor:IsValid() then
        local ClassName = Actor:GetClass():GetFName():ToString()
        if string.find(ClassName, "GameSession") or string.find(ClassName, "SN2GameSession") then
            pcall(function()
                Actor.MaxPlayers = MaxSlots
                Actor.MaxPartySize = MaxSlots
                print(string.format("[SN2SlotFreeHost] Hooked %s -> MaxPlayers set to %d", ClassName, MaxSlots))
            end)
        elseif string.find(ClassName, "GameMode") or string.find(ClassName, "SN2WorldGameMode") then
            pcall(function()
                if Actor.GameSession and Actor.GameSession:IsValid() then
                    Actor.GameSession.MaxPlayers = MaxSlots
                    Actor.GameSession.MaxPartySize = MaxSlots
                    print(string.format("[SN2SlotFreeHost] Hooked GameMode -> GameSession.MaxPlayers set to %d", MaxSlots))
                end
            end)
        end
    end
end)

-- Hook UUWEOnlineSessionSubsystem:HostSessionAsync to override MaxSessionPlayerCount
-- OFF by default. With it registered, the lobby's HostSession -> native HostSessionAsync
-- crashes the game inside UE4SS's native-hook path.
-- The limits are set directly before the call instead (cmd_host_once.lua). Set HOOK_HOSTASYNC=true to restore.
local HOOK_HOSTASYNC = false
if HOOK_HOSTASYNC then RegisterHook("/Script/UWESonar.UWEOnlineSessionSubsystem:HostSessionAsync", function(Context, HostingPlayerController, AllowAllFriends, GameModeAlias, ServerName, SaveSlot, SaveCheckpoint)
    local Subsystem = Context:get()
    if Subsystem and Subsystem:IsValid() then
        pcall(function()
            Subsystem.MaxSessionPlayerCount = MaxSlots
            print(string.format("[SN2SlotFreeHost] HostSessionAsync hooked -> MaxSessionPlayerCount forced to %d", MaxSlots))
        end)
    end
end) end

-- Background poller to initiate host session once game reaches main lobby
-- Idle until armed: the Host call only runs once the file HOST_ARMED exists next to this
-- script (Mods/SN2SlotFreeHost/HOST_ARMED). Without it the mod only reports what it sees.
-- Checked under both loader folders: release (ue4ss) and experimental (ue4ss-exp).
local ARM_PATHS = { "ue4ss-exp/Mods/SN2SlotFreeHost/HOST_ARMED", "ue4ss/Mods/SN2SlotFreeHost/HOST_ARMED" }
-- The container's arm marker (moonpool arm, and the service on every launch when ARM=1).
if os.getenv("SN2_CONTROL_WIN") then table.insert(ARM_PATHS, 1, os.getenv("SN2_CONTROL_WIN") .. "\\HOST_ARMED") end
-- The recipe's save choice (SAVE_NAME, moonpool host <save>); "Slot1" as the original.
local function save_slot()
    local ok, s = pcall(function() return _G.SN2_PICK_SAVE and _G.SN2_PICK_SAVE() end)
    if ok and type(s) == "string" and s ~= "" then return s end
    return "Slot1"
end
local function armed()
    for _, p in ipairs(ARM_PATHS) do
        local f = io.open(p, "r")
        if f then f:close() return true end
    end
    return false
end
-- Run fn under pcall and print what happened, so a failing Host call is logged, not swallowed.
local function try(label, fn)
    local ok, err = pcall(fn)
    if ok then
        print(string.format("[SN2SlotFreeHost] %s: returned without a Lua error", label))
    else
        print(string.format("[SN2SlotFreeHost] %s: FAILED: %s", label, tostring(err)))
    end
    return ok
end
local reported = false
-- The service arms before launch, so the marker is there before the lobby is. Wait for a Host
-- target (the lobby game mode, or the subsystem plus a PlayerController) for up to
-- ARM_WAIT_SECS before the one attempt; only then is the attempt spent.
local ARM_WAIT_SECS = tonumber(os.getenv("SN2_ARM_WAIT_SECS") or "") or 300
-- The lobby appears before the platform user's network login finishes; a Host call then fails
-- with "Could not retrieve UniqueNetID for Player" (the user was still
-- InitState:DoingNetworkLogin 2 s after the lobby). Hold the call ARM_SETTLE_SECS after the
-- lobby is first seen.
local ARM_SETTLE_SECS = tonumber(os.getenv("SN2_ARM_SETTLE_SECS") or "") or 30
local arm_waited, arm_wait_reported, settled = 0, false, 0
local function valid(o) return o ~= nil and o:IsValid() end
LoopAsync(2000, function()
    if attempted then return true end
    if not armed() then
        if not reported then
            print("[SN2SlotFreeHost] Idle: HOST_ARMED not present, Host call not made.")
            reported = true
        end
        return false
    end

    local Subsystem = FindFirstOf("UWEOnlineSessionSubsystem")
    local PC = FindFirstOf("PlayerController")
    local LobbyGameMode = FindFirstOf("BP_ClientLobbyGameMode_C")
    local ready = valid(LobbyGameMode) or (valid(Subsystem) and valid(PC))
    if not ready and arm_waited < ARM_WAIT_SECS then
        if not arm_wait_reported then
            print(string.format("[SN2SlotFreeHost] ARMED: waiting up to %ds for the lobby before the Host call", ARM_WAIT_SECS))
            arm_wait_reported = true
        end
        arm_waited = arm_waited + 2
        return false
    end
    if ready and settled < ARM_SETTLE_SECS then
        if settled == 0 then
            print(string.format("[SN2SlotFreeHost] lobby found; settling %ds before the Host call", ARM_SETTLE_SECS))
        end
        settled = settled + 2
        return false
    end

    -- One attempt only, whatever the outcome, so the call is never repeated.
    attempted = true
    print(string.format("[SN2SlotFreeHost] ARMED: making one Host call (lobby waited %ds)", arm_waited))
    print(string.format("[SN2SlotFreeHost] found: Subsystem=%s PlayerController=%s LobbyGameMode=%s",
        tostring(valid(Subsystem)), tostring(valid(PC)), tostring(valid(LobbyGameMode))))
    if Subsystem and Subsystem:IsValid() then
        try("set MaxSessionPlayerCount", function()
            Subsystem.MaxSessionPlayerCount = MaxSlots
            print(string.format("[SN2SlotFreeHost] MaxSessionPlayerCount now %s", tostring(Subsystem.MaxSessionPlayerCount)))
        end)
    end
    if LobbyGameMode and LobbyGameMode:IsValid() then
        -- What the lobby's Host button runs (BP_ClientLobbyGameMode::HostSession)
        host_ok = try("BP_ClientLobbyGameMode:HostSession", function()
            -- Live-read signature: GameModeAlias, ServerName, SaveSlot,
            -- SaveCheckpoint (FString each), VoiceChatMode (1-byte enum, 0 = first entry)
            print("[SN2SlotFreeHost] Host call: ServerName=" .. world_name() .. " SaveSlot=" .. save_slot())
            LobbyGameMode:HostSession("", world_name(), save_slot(), "", 0)
        end)
    elseif Subsystem and Subsystem:IsValid() and PC and PC:IsValid() then
        host_ok = try("UWEOnlineSessionSubsystem:HostSessionAsync", function()
            -- Live-read signature: HostingPlayerController, AllowAllFriends, GameModeAlias,
            -- ServerName, SaveSlot, SaveCheckpoint, VoiceChatMode (7 inputs, no out-param)
            print("[SN2SlotFreeHost] Host call: ServerName=" .. world_name() .. " SaveSlot=" .. save_slot())
            Subsystem:HostSessionAsync(PC, true, "", world_name(), save_slot(), "", 0)
        end)
    else
        print("[SN2SlotFreeHost] Host call NOT made: no lobby game mode and no subsystem+PlayerController")
    end
    -- After "Load map complete": wait for the world game mode, then (1) set the world GameSession
    -- limit and (2) if HOST_PRUNE, prune the host's PlayerState and unlock the lifepod goals (Beacon port).
    local PM = "[SN2SlotFreeHost] postmap: "
    local waited = 0
    LoopAsync(2000, function()
        waited = waited + 2
        local wgm = FindFirstOf("BP_SN2WorldGameMode_C")
        if not (wgm and wgm:IsValid()) then
            if waited >= 180 then print(PM .. "world game mode not seen in 180 s; post-map steps NOT run") return true end
            return false
        end
        ExecuteWithDelay(5000, function() ExecuteInGameThread(function()
            local gsess = FindFirstOf("GameSession")
            if gsess and gsess:IsValid() then
                local before = tostring(gsess.MaxPlayers)
                pcall(function() gsess.MaxPlayers = MaxSlots end)
                print(PM .. "world GameSession.MaxPlayers " .. before .. " -> " .. tostring(gsess.MaxPlayers))
            else
                print(PM .. "no world GameSession found")
            end
            if not HOST_PRUNE then print(PM .. "host prune is switched off (SN2_HOST_PRUNE=false); the host keeps its PlayerState") end
            -- Prune now (when on), then every 3 s until a real player has a body (the host's PlayerState
            -- can be re-added on a join), then unlock the three lifepod goals once. Gives up after 60 min.
            prune_host(PM)
            pcall(treat_host_state, PM)
            local tries, done = 0, false
            LoopAsync(3000, function()
                if done then return true end
                tries = tries + 1
                if tries > 1200 then print(PM .. "no real player with a body in 60 min; goals not unlocked") return true end
                ExecuteInGameThread(function()
                    if done then return end
                    if not host_state_treated then pcall(treat_host_state, PM) end
                    if not host_body_treated then pcall(treat_host_body, PM) end
                    local ok, real = pcall(prune_host, PM)
                    if ok and real then
                        done = true
                        if STORY_GOALS_ENABLED then
                            print(PM .. "real player with a body: " .. real .. "; unlocking lifepod story goals")
                            pcall(unlock_story_goals, PM)
                        else
                            print(PM .. "real player with a body: " .. real .. "; story-goal sharing is off")
                        end
                    end
                end)
                return false
            end)
        end) end)
        return true
    end)
    -- Report the session state a few times after the call
    local checks = 0
    LoopAsync(5000, function()
        checks = checks + 1
        if Subsystem and Subsystem:IsValid() then
            pcall(function()
                print(string.format("[SN2SlotFreeHost] after %ds: MaxSessionPlayerCount=%s", checks * 5,
                    tostring(Subsystem.MaxSessionPlayerCount)))
                if host_ok and not hosted and Subsystem.MaxSessionPlayerCount == MaxSlots then
                    hosted = true; _G.SN2_HOSTED = true
                    print(string.format("[SN2SlotFreeHost] hosted: Host call ok, session limit read back %d", MaxSlots))
                end
            end)
        end
        return checks >= 12
    end)
    return true
end)

-- The container's additions (control queue, status.json, idle freeze, slots).
local rok, rerr = pcall(require, "recipe")
if not rok then print("[SN2SlotFreeHost] recipe additions not loaded: " .. tostring(rerr)) end

print("[SN2SlotFreeHost] Mod loaded successfully.")
