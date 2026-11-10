#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  DATA="$BATS_TEST_TMPDIR/data"
  GAME="$BATS_TEST_TMPDIR/game"
  WIN="$GAME/Subnautica2/Binaries/Win64"
  U="$WIN/ue4ss"
  mkdir -p "$DATA/logs" "$DATA/ue4ss-local" "$U/UE4SS_Signatures"
  cp "$BATS_TEST_DIRNAME/fixtures/verify-fresh/pass/services.fixture" "$DATA/logs/services.log"
  cp "$BATS_TEST_DIRNAME/fixtures/verify-fresh/pass/game.fixture" "$DATA/logs/game.log"
  # The heartbeat sits 30 s in the past and every mtime is fixed: the Docker VM
  # clock can step back a second or two, which made "now" and "newer" flaky.
  sed "s/NOW/$(date -u -d "@$(($(date +%s) - 30))" +%FT%TZ)/" "$BATS_TEST_DIRNAME/fixtures/verify-fresh/pass/join_watch.fixture" >"$DATA/logs/join_watch.log"
  cp "$BATS_TEST_DIRNAME/fixtures/verify-fresh/pass/UE4SS.fixture" "$U/UE4SS.log"
  printf exe >"$WIN/Subnautica2-Win64-Shipping.exe"
  touch -t 202601010000 "$WIN/Subnautica2-Win64-Shipping.exe"
  printf dll >"$WIN/dwmapi.dll"; printf loader >"$U/UE4SS.dll"
  for s in FName_Constructor GNatives GUObjectHashTables StaticConstructObject; do printf sig >"$U/UE4SS_Signatures/$s.lua"; done
  # A shipped layout set for this exe (full sha256 in exe.sha256), applied.
  LAYOUTS="$BATS_TEST_TMPDIR/layouts"; mkdir -p "$LAYOUTS/fixture"
  hash=$(sha256sum "$WIN/Subnautica2-Win64-Shipping.exe" | cut -d' ' -f1)
  echo "$hash" >"$LAYOUTS/fixture/exe.sha256"
  for f in MemberVariableLayout VTableLayout; do printf '%s\n' "$f" >"$LAYOUTS/fixture/$f.ini"; cp "$LAYOUTS/fixture/$f.ini" "$U/$f.ini"; done
  sed -i "s/HASH/$hash/" "$DATA/logs/services.log"
  find "$U" -type f -exec touch -t 202601010100 {} +
  # The engine's own log, where the save load is proven. The
  # public Shipping build writes it in the Wine user's AppData.
  ELOG="$DATA/wine/drive_c/users/${USER:-$(id -un)}/AppData/Local/Subnautica2/Saved/Logs"
  mkdir -p "$ELOG"
  printf '%s\n' '[2026.11.01-08.29.02:503][158]LogLoad: LoadMap: /Game/Maps/Main/L_Main?Name=Player?listen?SaveSlotDisplayName=Slot1?SaveSlotName=Slot1?SaveCheckpoint=?VoiceChatMode=Proximity' >"$ELOG/Subnautica2.log"
  # PLAYER_SLOTS=8: the fixture logs record an 8-slot host (session limit 9).
  VERIFY=(env DISCORD_WEBHOOK_URL= PLAYER_SLOTS=8 SAVE_NAME=Slot1 DATA_DIR="$DATA" GAME_DIR="$GAME" UE4SS_LAYOUTS="$LAYOUTS" STEAM_BRANCH=public UE4SS_CHANNEL=pinned SN2_COMMON="$ROOT/scripts/common.sh" bash "$ROOT/scripts/verify-fresh.sh")
}

stage_fails() { [ "$status" -eq 1 ] && [[ "$output" == *"FAIL $1"* ]]; }

@test "fresh-host fixture passes every stage and JSON is machine-readable" {
  run "${VERIFY[@]}"
  [ "$status" -eq 0 ]; [ "$(grep -c '^PASS ' <<<"$output")" -eq 9 ]
  run "${VERIFY[@]}" --json
  [ "$status" -eq 0 ]; # the bats image has no python3 or jq: check the shape the panel parses
  [[ "$output" == '{"ok":true,"stages":['*']}' ]]; [ "$(grep -o '"status":"PASS"' <<<"$output" | wc -l)" -eq 9 ]
}

@test "fresh-host fails save stage when another slot was loaded" { run "${VERIFY[@]/SAVE_NAME=Slot1/SAVE_NAME=Slot2}"; stage_fails save; }
@test "fresh-host save stage with SAVE_NAME empty reads the slot the Host call named" {
  # The mod's prints land on one physical line with the next entry glued on, as in the real log.
  printf '%s' '[2026-11-01 08:29:00.0000000] [Lua] [SN2SlotFreeHost] Host call: ServerName=All Blue SaveSlot=Slot1[2026-11-01 08:29:00.4000000] [Lua] [SN2SlotFreeHost] BP_ClientLobbyGameMode:HostSession: returned without a Lua error' >>"$U/UE4SS.log"
  run "${VERIFY[@]/SAVE_NAME=Slot1/SAVE_NAME=}"; [[ "$output" == *"PASS save"* ]]
  printf '%s' '[2026-11-01 08:30:00.0000000] [Lua] [SN2SlotFreeHost] Host call: ServerName=All Blue SaveSlot=Slot2[2026-11-01 08:30:00.4000000] [Lua] [SN2SlotFreeHost] BP_ClientLobbyGameMode:HostSession: returned without a Lua error' >>"$U/UE4SS.log"
  run "${VERIFY[@]/SAVE_NAME=Slot1/SAVE_NAME=}"; stage_fails save
}
@test "fresh-host card stage needs a 2xx edit when a webhook is set" {
  run env DISCORD_WEBHOOK_URL=https://example.invalid/hook "${VERIFY[@]:2}"; stage_fails card
  echo '[2026-11-01T08:35:06Z] discord: PATCH /messages/1 -> HTTP 200 (rule: status)' >"$DATA/logs/discord.log"
  run env DISCORD_WEBHOOK_URL=https://example.invalid/hook "${VERIFY[@]:2}"; [[ "$output" == *"PASS card"* ]]
}
@test "fresh-host session lines are found under a path with spaces" {
  # The Wine prefix is under the data folder, so the space goes there.
  sp="$BATS_TEST_TMPDIR/Program Files (x86)"; mv "$DATA" "$sp"
  grep -v '^\[.*OnCreateSessionComplete\|Load map complete' "$sp/logs/game.log" >"$sp/logs/g2" || true; mv "$sp/logs/g2" "$sp/logs/game.log"
  printf '%s\n' '[2026.11.01-08.29.02:400][150]LogOnline: OnCreateSessionComplete Session: GameSession bWasSuccessful: 1' '[2026.11.01-08.29.10:000][200]LogLoad: Load map complete /Game/Maps/Main/L_Main' >>"$sp/wine/drive_c/users/${USER:-$(id -un)}/AppData/Local/Subnautica2/Saved/Logs/Subnautica2.log"
  run "${VERIFY[@]/DATA_DIR=*/DATA_DIR=$sp}"; [[ "$output" == *"PASS session"* ]]
}

@test "fresh-host fails Steam stage" { sed -i 's/signed in: true/signed in: false/' "$DATA/logs/services.log"; run "${VERIFY[@]}"; stage_fails steam; }
@test "fresh-host fails game stage" { rm "$WIN/Subnautica2-Win64-Shipping.exe"; run "${VERIFY[@]}"; stage_fails game; }
@test "fresh-host fails loader stage" { rm "$U/UE4SS_Signatures/GNatives.lua"; run "${VERIFY[@]}"; stage_fails loader; }
@test "fresh-host rejects a mixed-build loader folder" { touch -t 200001010000 "$U/UE4SS.dll"; run "${VERIFY[@]}"; stage_fails loader; [[ "$output" == *older-than-exe* ]]; }
@test "fresh-host fails layout stage: shipped set is for another exe" { echo 0000000000000000000000000000000000000000000000000000000000000000 >"$LAYOUTS/fixture/exe.sha256"; run "${VERIFY[@]}"; stage_fails layout; [[ "$output" == *no-layout-set-for* ]]; }
@test "fresh-host fails layout stage: set not applied" { echo other >"$U/VTableLayout.ini"; run "${VERIFY[@]}"; stage_fails layout; [[ "$output" == *not-applied:VTableLayout.ini* ]]; }
@test "fresh-host fails UE4SS stage" { sed -i '/Starting mods/d' "$U/UE4SS.log"; run "${VERIFY[@]}"; stage_fails ue4ss; }
@test "fresh-host fails session stage" { sed -i '/postmap: world GameSession/d' "$U/UE4SS.log"; run "${VERIFY[@]}"; stage_fails session; }
@test "fresh-host fails session stage without the host prune" { sed -i '/prune host PlayerState/d' "$U/UE4SS.log"; run "${VERIFY[@]}"; stage_fails session; [[ "$output" == *"prune host"* ]]; }
@test "fresh-host fails watcher stage" { sed -i 's/heartbeat: game RUNNING/heartbeat: game NOT RUNNING/' "$DATA/logs/join_watch.log"; run "${VERIFY[@]}"; stage_fails watcher; }

@test "fresh-host fails session stage on hook and prune lines without the session readback" {
  sed -i '/hosted: Host call ok/d' "$U/UE4SS.log"; run "${VERIFY[@]}"; stage_fails session
}
