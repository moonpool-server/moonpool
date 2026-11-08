#!/usr/bin/env bats
# Tests for the moonpool side of the file-drop control queue. A fake "mod" in
# the background answers requests the way SN2SlotFreeHost does, so these run
# without the game.
# Each @test runs in its own subshell, so an export in one cannot leak into another:
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0

setup() {
  CTL="$BATS_TEST_DIRNAME/../bin/moonpool"
  export SN2_CONTROL_DIR="$BATS_TEST_TMPDIR/control"
  export SN2_IN_CONTAINER=1 SN2_TIMEOUT=3
  mkdir -p "$SN2_CONTROL_DIR"/{inbox,outbox,tmp,receipts}
  chmod 700 "$SN2_CONTROL_DIR"
}

# Answer the first request that appears the way the mod does ({v, id, ok,
# data, error}), echoing its id and command: fake_mod [true [DATA-JSON]],
# fake_mod false [ERROR-CODE], or fake_mod raw '<the whole answer>'.
# FAKE_REPLY_ID answers under another id than the request's.
# Reach inside bin/moonpool: mp '<python statement>' with the CLI loaded as module m.
mp() { python3 -c "import importlib.util as u, importlib.machinery as k, sys; s = u.spec_from_file_location('m', sys.argv[1], loader=k.SourceFileLoader('m', sys.argv[1])); m = u.module_from_spec(s); s.loader.exec_module(m); exec(sys.argv[2])" "$CTL" "$1"; }
fake_mod() {
  local ok=${1:-true} body
  case $ok in
    true) body="\"data\":${2:-{\}}" ;;
    false) body="\"data\":{},\"error\":\"${2:-unknown_player}\"" ;;
    raw) body=$2 ;;
  esac
  (
    for _ in $(seq 1 60); do
      for f in "$SN2_CONTROL_DIR"/inbox/*.json; do
        [ -f "$f" ] || continue
        # Claim it first (two fakes may be polling), then take the game thread's time.
        mv "$f" "$f.claimed" 2>/dev/null || continue
        f="$f.claimed"
        id=$(sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p' "$f")
        # When each request was claimed and answered: the lock tests read order from this,
        # never from wall time (the image's sleep can return early).
        echo "$EPOCHREALTIME claim $id" >>"$SN2_CONTROL_DIR/fake.log"
        sleep "${FAKE_DELAY:-0}"
        cmd=$(sed -n 's/.*"cmd":"\([a-z_]*\)".*/\1/p' "$f")
        cp "$f" "$SN2_CONTROL_DIR/receipts/request.json"
        if [ "$ok" = raw ]; then printf '%s' "$body" >"$SN2_CONTROL_DIR/outbox/.$id.tmp"
        else
          printf '{"v":1,"accepts":[1],"id":"%s","ok":%s,"cmd":"%s",%s,"meta":{"game_build_id":"test-build","mod_version":"1.0.0"}}' "${FAKE_REPLY_ID:-$id}" "$ok" "$cmd" "$body" \
            >"$SN2_CONTROL_DIR/outbox/.$id.tmp"
        fi
        mv "$SN2_CONTROL_DIR/outbox/.$id.tmp" "$SN2_CONTROL_DIR/outbox/$id.json"
        echo "$EPOCHREALTIME answer $id" >>"$SN2_CONTROL_DIR/fake.log"
        rm -f "$f"
        exit 0
      done
      sleep 0.1
    done
  ) &
}

@test "build_request emits versioned JSON with id, cmd and args" {
  run mp 'print(m.build_request("abc123", "players", []))'
  [ "$status" -eq 0 ]
  [[ $output == '{"v":1,"id":"abc123","cmd":"players","args":{},"ts":'* ]]
}

@test "protocol schemas validate real v1 request and response examples" {
  run python3 tests/validate_protocol_schemas.py
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ $output == *"2 protocol examples validated"* ]]
}

@test "Lua protocol checks stale requests, duplicate nonces, versions and UTF-8" {
  run lua5.4 tests/lua/protocol_spec.lua
  [ "$status" -eq 0 ]
  [[ $output == *"11 tests, 0 failures"* ]]
}

@test "Lua access policy kicks banned names once per presence" {
  run lua5.4 tests/lua/access_spec.lua
  [ "$status" -eq 0 ]
  [[ $output == *"all passed"* ]]
}

@test "player arguments are JSON-escaped" {
  run mp 'print(m.build_request("x", "player", ["a\"b", "Give DA_X_ItemType 2"]))'
  [ "$status" -eq 0 ]
  [[ $output == *'"cmd":"player","args":{"player":"a\"b","command":"Give DA_X_ItemType 2"}'* ]]
}

@test "nonce is 32 hex characters and differs each time" {
  a=$(mp 'print(m.new_nonce())')
  b=$(mp 'print(m.new_nonce())')
  [[ $a =~ ^[0-9a-f]{32}$ ]]
  [ "$a" != "$b" ]
}

@test "players round-trips through inbox and outbox" {
  fake_mod true
  run "$CTL" players
  wait
  [ "$status" -eq 0 ]
  [[ $output == *'"ok":true'* ]]
  [[ $output == *'"cmd":"players"'* ]]
  # request was dropped atomically: nothing left in tmp or inbox
  [ -z "$(ls -A "$SN2_CONTROL_DIR/tmp")" ]
  [ -z "$(ls "$SN2_CONTROL_DIR"/inbox/*.json 2>/dev/null)" ]
}

@test "request file is private (mode 600)" {
  fake_mod true
  "$CTL" players >/dev/null
  wait
  [ "$(stat -c '%a' "$SN2_CONTROL_DIR/receipts/request.json")" = "600" ] ||
    [ "$(stat -c '%a' "$SN2_CONTROL_DIR/receipts/request.json")" = "644" ] # cp may reset mode on some filesystems
}

@test "a refused command exits 77 and names the mod's reason" {
  fake_mod false
  run "$CTL" players
  wait
  [ "$status" -eq 77 ]
  [[ $output == *"refused by the mod: no connected player has that name (unknown_player)"* ]]
}

@test "no answer times out and removes the request" {
  SN2_TIMEOUT=1 run "$CTL" players
  [ "$status" -ne 0 ]
  [[ $output == *"no answer from the mod"* ]]
  [ -z "$(ls "$SN2_CONTROL_DIR"/inbox/*.json 2>/dev/null)" ]
}

@test "malformed and oversized responses fail immediately under protocol_error" {
  fake_mod raw '{not json'
  run "$CTL" --json players
  wait
  [ "$status" -eq 70 ]; [ "$(jq -r .code <<<"$output")" = protocol_error ]
  fake_mod raw "$(printf '{"v":1,"accepts":[1],"id":"x","ok":true,"data":{"pad":"'; head -c 66000 /dev/zero | tr '\0' x; printf '"},"meta":{"game_build_id":"x","mod_version":"1"}}')"
  run "$CTL" --json players
  wait
  [ "$status" -eq 70 ]; [[ $(jq -r .message <<<"$output") == *"exceeds 65536"* ]]
}

@test "a response without a version and a version mismatch give one actionable error" {
  fake_mod raw '{"id":"0123456789abcdef0123456789abcdef","ok":true,"data":{},"meta":{"game_build_id":"x","mod_version":"old"}}'
  run "$CTL" --json players
  wait
  [ "$status" -eq 70 ]; [[ $(jq -r .message <<<"$output") == *"missing protocol version"* ]]
  [ "$(jq -r .next_action <<<"$output")" = "Deploy matching copies of bin/moonpool and the SN2SlotFreeHost Lua files, then retry." ]
  fake_mod raw '{"v":2,"accepts":[2],"id":"0123456789abcdef0123456789abcdef","ok":true,"data":{},"meta":{"game_build_id":"x","mod_version":"2"}}'
  run "$CTL" --json players
  wait
  [ "$status" -eq 70 ]; [[ $(jq -r .message <<<"$output") == *"not supported"* ]]
}

@test "symlinked and non-regular queue entries are refused before submission" {
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$SN2_CONTROL_DIR/outbox/bad.json"
  run "$CTL" --json players
  [ "$status" -eq 70 ]; [[ $(jq -r .message <<<"$output") == *"symlink or non-regular"* ]]
  rm "$SN2_CONTROL_DIR/outbox/bad.json"
  mkfifo "$SN2_CONTROL_DIR/inbox/fifo.json"
  run "$CTL" --json players
  [ "$status" -eq 70 ]; [[ $(jq -r .message <<<"$output") == *"symlink or non-regular"* ]]
}

@test "a full inbox is bounded and refused without adding a request" {
  for n in $(seq 1 128); do printf '{}' >"$SN2_CONTROL_DIR/inbox/$(printf '%032x' "$n").json"; done
  run "$CTL" --json players
  [ "$status" -eq 69 ]; [[ $(jq -r .message <<<"$output") == *"inbox is full"* ]]
  [ "$(find "$SN2_CONTROL_DIR/inbox" -type f | wc -l)" -eq 128 ]
}

@test "restart recovery removes dead client temps but preserves orphaned inbox requests" {
  printf old >"$SN2_CONTROL_DIR/tmp/dead.json"
  touch -t 202001010000 "$SN2_CONTROL_DIR/tmp/dead.json"
  printf '{}' >"$SN2_CONTROL_DIR/inbox/0123456789abcdef0123456789abcdef.json"
  run mp 'm.check_control_dir(); m.queue_housekeeping()'
  [ "$status" -eq 0 ]; [ ! -e "$SN2_CONTROL_DIR/tmp/dead.json" ]
  [ -f "$SN2_CONTROL_DIR/inbox/0123456789abcdef0123456789abcdef.json" ]
  grep -q 'submitted inbox entries' scripts/launch-headless.sh
}

@test "refuses a control directory that is not mode 700" {
  chmod 755 "$SN2_CONTROL_DIR"
  run "$CTL" players
  [ "$status" -ne 0 ]
  [[ $output == *"expected 700"* ]]
}

@test "save queues a forced host save and returns the mod's answer" {
  fake_mod true '{"forced":true,"queued":true}'
  run "$CTL" server save
  wait
  [ "$status" -eq 0 ]
  grep -q '"cmd":"save"' "$SN2_CONTROL_DIR/receipts/request.json"
  [[ $output == *'"forced":true'* ]]
}

@test "unknown command fails with usage" {
  run "$CTL" frobnicate
  [ "$status" -ne 0 ]
  [[ $output == *"Usage: moonpool"* ]]
}

@test "arm creates HOST_ARMED and disarm removes it, without the mod" {
  run "$CTL" server arm
  [ "$status" -eq 0 ]
  [ -f "$SN2_CONTROL_DIR/HOST_ARMED" ]
  run "$CTL" server disarm
  [ "$status" -eq 0 ]
  [ ! -e "$SN2_CONTROL_DIR/HOST_ARMED" ]
}

# ---- saves, host and restore ----------------------------------------------
# A save folder, a run folder and a stand-in save-stage.sh that records each
# snapshot, so the order "stage first, then overwrite" can be checked.
save_env() {
  export SN2_SAVE_DIR="$BATS_TEST_TMPDIR/saves" SN2_RUN_DIR="$BATS_TEST_TMPDIR/run"
  export SN2_BIN="$BATS_TEST_TMPDIR/bin" SN2_RESTART_WAIT=0
  export STAGED="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$SN2_SAVE_DIR" "$SN2_RUN_DIR" "$SN2_BIN"
  printf '#!/bin/sh\nmkdir -p "%s" && cp -a "%s"/. "%s"/\n' \
    "$STAGED" "$SN2_SAVE_DIR" "$STAGED" >"$SN2_BIN/save-stage.sh"
  chmod +x "$SN2_BIN/save-stage.sh"
}

# A backup archive holding the given files (relative paths), each with "new".
make_backup() {
  local out=$1; shift
  local d="$BATS_TEST_TMPDIR/bk"
  mkdir -p "$d"
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo new >"$d/$f"; done
  tar -czf "$out" -C "$d" .
}

@test "saves lists worlds newest first, skipping settings files" {
  save_env
  echo a >"$SN2_SAVE_DIR/Slot1.sav"; touch -d '2026-10-30 10:00:00' "$SN2_SAVE_DIR/Slot1.sav"
  echo bb >"$SN2_SAVE_DIR/Slot2.sav"; touch -d '2026-10-31 16:00:27' "$SN2_SAVE_DIR/Slot2.sav"
  echo x >"$SN2_SAVE_DIR/GameSettings.sav"
  TZ=UTC run "$CTL" server saves
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == SAVE* ]]
  [[ ${lines[1]} == Slot2* ]]
  [[ ${lines[2]} == Slot1* ]]
  [ "${#lines[@]}" -eq 3 ]
  [[ $output != *GameSettings* ]]
}

@test "saves fails plainly when there is no save folder" {
  save_env
  SN2_SAVE_DIR="$BATS_TEST_TMPDIR/none" run "$CTL" server saves
  [ "$status" -eq 69 ]
  [[ $output == *"no save folder yet"* ]]
}

@test "host <save> writes SAVE_SELECT and restarts the game" {
  save_env
  run "$CTL" server host Slot2
  [ "$status" -eq 0 ]
  [ "$(cat "$SN2_CONTROL_DIR/SAVE_SELECT")" = "Slot2" ]
  # stop-game set the hold and start-game cleared it again
  [ ! -e "$SN2_RUN_DIR/stopped" ]
  [[ $output == *"re-hosting on Slot2"* ]]
}

@test "host refuses a save name that could escape the folder" {
  save_env
  run "$CTL" server host '../evil'
  [ "$status" -eq 64 ]
  [ ! -e "$SN2_CONTROL_DIR/SAVE_SELECT" ]
}

# A player's world as a zip, and the game's later word on loading it in a fake log.
world_zip() { (cd "$BATS_TEST_TMPDIR" && mkdir -p w && echo world >w/savegame_2.sav && echo bak >w/savegame_2_0.bak && python3 -m zipfile -c "$1" w/savegame_2.sav w/savegame_2_0.bak); }
# The game empties its log in place on a restart, so the new result lands in a shorter file.
game_says() { export SN2_UE_LOG="$BATS_TEST_TMPDIR/game.log"; printf 'LogSaveSystem: Loading save slot: %s\nLogGameMode: Save system initialize with result: (LoadGameSucceeded)\n' "$1" >"$SN2_UE_LOG"; (sleep 1; printf 'LogSaveSystem: Loading save slot: %s
LogGameMode: Save system initialize with result: (%s)
' "$1" "$2" >"$SN2_UE_LOG") & }

@test "import puts a player's world in, re-hosts on it, and keeps it when the game loads it" {
  save_env
  echo old >"$SN2_SAVE_DIR/Slot1.sav"; echo Slot1 >"$SN2_CONTROL_DIR/SAVE_SELECT"
  world_zip "$BATS_TEST_TMPDIR/w.zip"
  game_says savegame_2 LoadGameSucceeded
  printf '{"hosted":true,"ts":9999999999}' >"$SN2_CONTROL_DIR/readiness.json"
  run "$CTL" server import "$BATS_TEST_TMPDIR/w.zip"
  [ "$status" -eq 0 ] && [[ $output == *"savegame_2 loaded and is hosted"* ]]
  [ "$(cat "$SN2_SAVE_DIR/savegame_2.sav")" = world ] && [ -f "$SN2_SAVE_DIR/savegame_2_0.bak" ]
  [ "$(cat "$SN2_CONTROL_DIR/SAVE_SELECT")" = savegame_2 ] && [ "$(cat "$STAGED/Slot1.sav")" = old ]
}

@test "import takes back out a world the game cannot load and hosts the previous one again" {
  save_env
  echo old >"$SN2_SAVE_DIR/Slot1.sav"; echo Slot1 >"$SN2_CONTROL_DIR/SAVE_SELECT"
  world_zip "$BATS_TEST_TMPDIR/w.zip"
  game_says Reef LoadGameFailed
  run "$CTL" server import "$BATS_TEST_TMPDIR/w.zip" Reef
  [ "$status" -eq 77 ]
  [[ $output == *"could not load Reef (LoadGameFailed)"* ]]
  [ ! -e "$SN2_SAVE_DIR/Reef.sav" ] && [ ! -e "$SN2_SAVE_DIR/Reef_0.bak" ]
  [ "$(cat "$SN2_CONTROL_DIR/SAVE_SELECT")" = Slot1 ] && [ "$(cat "$SN2_SAVE_DIR/Slot1.sav")" = old ]
}

@test "import refuses a name the server already has and changes nothing" {
  save_env
  echo old >"$SN2_SAVE_DIR/savegame_2.sav"
  world_zip "$BATS_TEST_TMPDIR/w.zip"
  run "$CTL" server import "$BATS_TEST_TMPDIR/w.zip"
  [ "$status" -eq 77 ] && [[ $output == *"already has a world called savegame_2"* ]]
  [ "$(cat "$SN2_SAVE_DIR/savegame_2.sav")" = old ]
}

@test "restore refuses a backup without a .sav and changes nothing" {
  save_env
  echo old >"$SN2_SAVE_DIR/Slot1.sav"
  make_backup "$BATS_TEST_TMPDIR/bad.tar.gz" userdata/123/remote/x.vdf
  run "$CTL" server restore "$BATS_TEST_TMPDIR/bad.tar.gz"
  [ "$status" -eq 77 ]
  [[ $output == *"holds no save (.sav) file"* ]]
  [ "$(cat "$SN2_SAVE_DIR/Slot1.sav")" = "old" ]
  [ ! -e "$STAGED" ]
}

@test "restore refuses a named save the backup does not hold" {
  save_env
  make_backup "$BATS_TEST_TMPDIR/b.tar.gz" saves/Slot1.sav
  run "$CTL" server restore "$BATS_TEST_TMPDIR/b.tar.gz" Slot9
  [ "$status" -eq 77 ]
  [[ $output == *"has no Slot9.sav"* ]]
}

@test "restore stages the current saves first, then puts the backup back and re-hosts" {
  save_env
  echo old >"$SN2_SAVE_DIR/Slot1.sav"
  make_backup "$BATS_TEST_TMPDIR/b.tar.gz" saves/Slot1.sav
  run "$CTL" server restore "$BATS_TEST_TMPDIR/b.tar.gz" Slot1
  [ "$status" -eq 0 ]
  [ "$(cat "$STAGED/Slot1.sav")" = "old" ]
  [ "$(cat "$SN2_SAVE_DIR/Slot1.sav")" = "new" ]
  [ "$(cat "$SN2_CONTROL_DIR/SAVE_SELECT")" = "Slot1" ]
  [[ $output == *"current saves were staged first"* ]]
}

@test "restore warns online players before stopping and names the backup" {
  save_env
  echo old >"$SN2_SAVE_DIR/Slot1.sav"
  make_backup "$BATS_TEST_TMPDIR/reef-backup.tar.gz" saves/Slot1.sav
  printf '{"hosted":true}' >"$SN2_CONTROL_DIR/readiness.json"
  printf '{"players":[{"name":"SN2 Host"},{"name":"Ada"}]}' >"$SN2_CONTROL_DIR/status.json"
  cat >"$SN2_BIN/restart-warning.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/restart-warning.call"
[ ! -e "$SN2_RUN_DIR/stopped" ]
SH
  chmod +x "$SN2_BIN/restart-warning.sh"
  run "$CTL" server restore "$BATS_TEST_TMPDIR/reef-backup.tar.gz" Slot1
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/restart-warning.call")" = "run restoring reef-backup.tar.gz" ]
}

@test "restore uses the newest timestamp directory in an archive" {
  save_env
  local tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  cat >"$tools/find" <<'EOF'
#!/bin/sh
/usr/bin/find "$@" | LC_ALL=C sort
EOF
  chmod +x "$tools/find"
  make_backup "$BATS_TEST_TMPDIR/b.tar.gz" \
    sn2-staging/20261103T120000Z/SaveGames/Slot1.sav \
    sn2-staging/20261103T130000Z/SaveGames/Slot2.sav
  PATH="$tools:$PATH" run "$CTL" server restore "$BATS_TEST_TMPDIR/b.tar.gz"
  [ "$status" -eq 0 ]
  [ ! -e "$SN2_SAVE_DIR/Slot1.sav" ]
  [ "$(cat "$SN2_SAVE_DIR/Slot2.sav")" = "new" ]
}

@test "restore all replaces live saves after keeping a dated safety copy" {
  save_env
  echo old-one >"$SN2_SAVE_DIR/Slot1.sav"
  echo old-extra >"$SN2_SAVE_DIR/Slot9.sav"
  make_backup "$BATS_TEST_TMPDIR/b.tar.gz" sn2-staging/20261103T130000Z/SaveGames/Slot1.sav
  run "$CTL" server restore "$BATS_TEST_TMPDIR/b.tar.gz"
  [ "$status" -eq 0 ]
  [ "$(cat "$SN2_SAVE_DIR/Slot1.sav")" = "new" ]
  [ ! -e "$SN2_SAVE_DIR/Slot9.sav" ]
  safety=("$BATS_TEST_TMPDIR"/saves.pre-restore-*)
  [ "${#safety[@]}" -eq 1 ]
  [ "$(cat "${safety[0]}/Slot1.sav")" = "old-one" ]
  [ "$(cat "${safety[0]}/Slot9.sav")" = "old-extra" ]
}

@test "restore stops when the snapshot of the current saves fails" {
  save_env
  echo old >"$SN2_SAVE_DIR/Slot1.sav"
  printf '#!/bin/sh\nexit 1\n' >"$SN2_BIN/save-stage.sh"
  make_backup "$BATS_TEST_TMPDIR/b.tar.gz" saves/Slot1.sav
  run "$CTL" server restore "$BATS_TEST_TMPDIR/b.tar.gz"
  [ "$status" -eq 77 ]
  [[ $output == *"could not snapshot"* ]]
  [ "$(cat "$SN2_SAVE_DIR/Slot1.sav")" = "old" ]
}

# ---- friends, invite and cmd -----------------------------------------------
# A Steam folder with one signed-in account and two friends, shaped like the
# client's own loginusers.vdf and localconfig.vdf.
steam_env() {
  export SN2_STEAM_DIR="$BATS_TEST_TMPDIR/steam"
  mkdir -p "$SN2_STEAM_DIR/config" "$SN2_STEAM_DIR/userdata/1000/config"
  printf '"users"\n{\n\t"76561197960266728"\n\t{\n\t\t"AccountName"\t"host"\n\t}\n}\n' \
    >"$SN2_STEAM_DIR/config/loginusers.vdf"
  printf '"UserLocalConfigStore"\n{\n\t"friends"\n\t{\n\t\t"111"\n\t\t{\n\t\t\t"name"\t"Alice"\n\t\t}\n\t\t"222"\n\t\t{\n\t\t\t"name"\t"Bob B"\n\t\t}\n\t}\n}\n' \
    >"$SN2_STEAM_DIR/userdata/1000/config/localconfig.vdf"
}

@test "friends prints the friend code and each friend from Steam's files" {
  steam_env
  run "$CTL" players friends
  [ "$status" -eq 0 ]
  [[ $output == *"host friend code: 1000"* ]]
  [[ $output == *"111  Alice"* ]]
  [[ $output == *"222  Bob B"* ]]
}

@test "friends fails plainly before the sign-in" {
  export SN2_STEAM_DIR="$BATS_TEST_TMPDIR/nosteam"
  run "$CTL" players friends
  [ "$status" -eq 69 ]
  [[ $output == *"sign in on the viewer page"* ]]
}

@test "ban add, list and remove manage the control policy without using protocol v1" {
  run "$CTL" ban add Alice "repeated disruption"
  [ "$status" -eq 0 ]
  [ ! -e "$SN2_CONTROL_DIR/receipts/request.json" ]
  grep -Fxq $'Alice\trepeated disruption' "$SN2_CONTROL_DIR/bans.txt"

  run "$CTL" --json ban list
  [ "$status" -eq 0 ]
  jq -e '.command == "ban.list" and .data.bans == [{"identifier":"Alice","reason":"repeated disruption"}]' <<<"$output"

  run "$CTL" ban add alice "new reason"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$SN2_CONTROL_DIR/bans.txt")" -eq 1 ]
  grep -Fxq $'alice\tnew reason' "$SN2_CONTROL_DIR/bans.txt"

  run "$CTL" --json ban remove ALICE
  [ "$status" -eq 0 ]
  jq -e '.data.removed == true' <<<"$output"
  [ ! -s "$SN2_CONTROL_DIR/bans.txt" ]
}

@test "ban add Steam ID persists first and asks the web-session helper to remove the friend" {
  stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"%s/remove.args"\n' "$BATS_TEST_TMPDIR" >"$stub/friend-accept.py"
  chmod +x "$stub/friend-accept.py"
  run env SN2_BIN="$stub" AUTO_ACCEPT_FRIENDS=1 "$CTL" ban add 76561198000000022 "do not readmit"
  [ "$status" -eq 0 ]
  grep -Fxq -- '--remove 76561198000000022' "$BATS_TEST_TMPDIR/remove.args"
  grep -Fxq $'76561198000000022\tdo not readmit' "$SN2_CONTROL_DIR/bans.txt"
}

@test "ban add without AUTO_ACCEPT_FRIENDS never touches the Steam web session" {
  stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
  printf '#!/bin/sh\ntouch "%s/called"\n' "$BATS_TEST_TMPDIR" >"$stub/friend-accept.py"
  chmod +x "$stub/friend-accept.py"
  run env SN2_BIN="$stub" "$CTL" ban add 76561198000000022 "do not readmit"
  [ "$status" -eq 0 ]
  [[ $output == *"can still join until you remove them in the viewer"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/called" ]
}

@test "invite adds the ID to the allowlist once" {
  run "$CTL" players invite 76561198000000000
  [ "$status" -eq 0 ]
  run "$CTL" players invite 76561198000000000
  [ "$status" -eq 0 ]
  [ "$(cat "$SN2_CONTROL_DIR/allowlist.txt")" = 76561198000000000 ]
  [ -z "$(ls "$SN2_CONTROL_DIR/inbox")" ]
}

@test "invite takes a profile link" {
  run "$CTL" players invite https://steamcommunity.com/profiles/76561198000000000/
  [ "$status" -eq 0 ]
  [ "$(cat "$SN2_CONTROL_DIR/allowlist.txt")" = 76561198000000000 ]
}

@test "invite refuses a custom /id/ link and junk, and lists nobody" {
  for bad in https://steamcommunity.com/id/somebody https://steamcommunity.com/id/76561198000000000 https://evil.example/profiles/76561198000000000 somebody 76561198; do
    run "$CTL" players invite "$bad"
    [ "$status" -eq 64 ]
  done
  [ ! -e "$SN2_CONTROL_DIR/allowlist.txt" ]
}

card() { python3 "$BATS_TEST_DIRNAME/../scripts/discord-notify.py" --dry-run status | grep '^{' | jq -c '.embeds[0]'; }
# ---- discord-notify.py: posting policy ----
# The queue state lives in the data volume, so the dry-run tests drive it with a
# fixed clock (SN2_NOW) and post nothing.
policy_env() {
  export DATA_DIR="$BATS_TEST_TMPDIR/data" CONTROL_DIR="$SN2_CONTROL_DIR" PLAYER_SLOTS=4
  export STEAM_BRANCH=public HOST_NAME="SN2 Host"
  LOG_DIR="$DATA_DIR/logs" # common.sh derives it from DATA_DIR
  mkdir -p "$LOG_DIR" "$DATA_DIR/discord"
  DN="$BATS_TEST_DIRNAME/../scripts/discord-notify.py"
}

# ---- player services ---------------------------------------------------------

@test "the item and teleport shortcuts are gone, and console lines pass as given" {
  run "$CTL" give Alice Builder 1
  [ "$status" -ne 0 ]
  run "$CTL" home Alice
  [ "$status" -ne 0 ]
  run mp 'print(m.player_line(["Alice", "Heal"]))'
  [ "$output" = "Heal" ]
}

@test "player refuses a chained line and a missing command" {
  run mp 'print(m.player_line(["Alice", "Heal; Quit"]))'
  [ "$status" -ne 0 ]
  [[ $output == *"one console command"* ]]
  run "$CTL" diag console Alice
  [ "$status" -ne 0 ]
}

@test "a console line drops one queue file naming the player and the line" {
  fake_mod
  run "$CTL" diag console "SN2 Host" Heal
  [ "$status" -eq 0 ]
  grep -q '"cmd":"player","args":{"player":"SN2 Host","command":"Heal"}' "$SN2_CONTROL_DIR/receipts/request.json"
}

@test "slots 8 drops one queue file with the number" {
  fake_mod
  run "$CTL" server slots 8
  [ "$status" -eq 0 ]
  grep -q '"cmd":"slots","args":{"slots":8}' "$SN2_CONTROL_DIR/receipts/request.json"
}

@test "slots strips a leading zero and stays a JSON number" {
  fake_mod
  run "$CTL" server slots 08
  [ "$status" -eq 0 ]
  grep -q '"args":{"slots":8}' "$SN2_CONTROL_DIR/receipts/request.json"
}

@test "slots refuses 0, 64, words and no argument, writing nothing" {
  for bad in 0 64 eight -3 ""; do
    run "$CTL" server slots $bad
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage: moonpool server slots"* ]]
  done
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
}

@test "friend-code drops one queue file; --force rides along as a JSON boolean" {
  fake_mod
  run "$CTL" diag friend-code
  [ "$status" -eq 0 ]
  grep -q '"cmd":"friend_code","args":{}' "$SN2_CONTROL_DIR/receipts/request.json"
  fake_mod
  run "$CTL" diag friend-code --force
  [ "$status" -eq 0 ]
  grep -q '"cmd":"friend_code","args":{"force":true}' "$SN2_CONTROL_DIR/receipts/request.json"
}

@test "unlocks refuses more than one player, or an empty one, writing nothing" {
  run "$CTL" unlocks a b
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage: moonpool unlocks [player]"* ]]
  run "$CTL" unlocks ""
  [ "$status" -eq 64 ]
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
}

@test "unlock replay passes its fake-game Lua spec" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/unlock_replay_spec.lua
  [ "$status" -eq 0 ]
}

@test "friend-code refuses other arguments, writing nothing" {
  run "$CTL" diag friend-code now
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: moonpool diag friend-code"* ]]
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
}

@test "friend-code view model logic passes its fake-game Lua spec" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/friend_code_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "in-game beacon admin policy passes its pure Lua spec" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/admin_signal_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all passed"* ]]
}

@test "idle policy and slots range pass the stub-clock Lua spec" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/idle_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *", 0 failures"* ]]
}

@test "settings.yaml parses and every key without a verified command is refused" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/settings_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *", 0 failures"* ]]
}

@test "launch-cinematic join hold passes the fake tag timeline spec" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/cinematic_hold_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *", 0 failures"* ]]
}

@test "hosted poll scans only on player changes or the safety interval" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/hosted_poll_spec.lua
  [ "$status" -eq 0 ]
}

@test "SN2SlotFreeHost loads with the recipe additions under stubbed UE4SS" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/host_mod_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

@test "SN2SlotFreeHost on a fake game: one Host call, limits read back, prune, goals once, slots" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/host_behaviour_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "kick runs KickPlayer as the host" {
  fake_mod
  run "$CTL" players kick Bob
  [ "$status" -eq 0 ]
  grep -q '"cmd":"kick","args":{"player":"Bob"}' "$SN2_CONTROL_DIR/receipts/request.json"
}



@test "voice range passes the fake ping store Lua spec" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/voice_range_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all passed"* ]]
}

@test "crash-sensitive game calls stay on the dump-derived allowlist" {
  command -v lua5.4 >/dev/null || skip "lua5.4 not installed (the pre-commit image adds it)"
  run lua5.4 tests/lua/game_method_allowlist_spec.lua
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a refused player request fails moonpool" {
  fake_mod false
  run "$CTL" diag console Nobody Heal
  [ "$status" -ne 0 ]
  [[ -f "$SN2_CONTROL_DIR/receipts/request.json" ]]
}

# --- the viewer's password (scripts/common.sh viewer_password) ----------------
@test "viewer password: VNC_PASSWORD wins, else one is made once at mode 600 and kept" {
  f="$BATS_TEST_TMPDIR/viewer-password"
  run bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; VNC_PASSWORD=mine VIEWER_PASSWORD_FILE='$f' viewer_password"
  [ "$output" = mine ] && [ ! -e "$f" ]
  run bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; VNC_PASSWORD= VIEWER_PASSWORD_FILE='$f' viewer_password"
  [ "$status" -eq 0 ] && [ "${#output}" -ge 12 ] && [ "$(stat -c %a "$f")" = 600 ]
  first=$output
  run bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; VNC_PASSWORD= VIEWER_PASSWORD_FILE='$f' viewer_password"
  [ "$output" = "$first" ]
}

@test "moonpool diag viewer says the address and the password the viewer holds" {
  printf 'kept-secret' >"$BATS_TEST_TMPDIR/viewer-password"
  run env VIEWER_PASSWORD_FILE="$BATS_TEST_TMPDIR/viewer-password" VIEWER_BIND=127.0.0.1 NOVNC_PORT=8080 VNC_PASSWORD= "$CTL" --json diag viewer
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.data.address, .data.password' <<<"$output")" = $'http://127.0.0.1:8080/vnc.html\nkept-secret' ]
  run env VNC_PASSWORD=mine "$CTL" diag viewer
  [[ "$output" == *'password mine'* ]]
}

# --- Steam sign-in check (scripts/common.sh steam_signed_in) ---------------
# Two account-file shapes: an older client's (MostRecent "1") and the current
# client's (AutoLogin "1", no MostRecent).

signin_env() {
  FIX="$BATS_TEST_DIRNAME/fixtures"
  LOGS="$BATS_TEST_TMPDIR/steamlogs"
  mkdir -p "$LOGS" "$BATS_TEST_TMPDIR/bin"
  # pgrep stand-in: the client counts as running when STEAM_UP=1.
  # shellcheck disable=SC2016 # $STEAM_UP is expanded by the stand-in, not here
  printf '#!/bin/sh\n[ "$STEAM_UP" = 1 ]\n' >"$BATS_TEST_TMPDIR/bin/pgrep"
  chmod +x "$BATS_TEST_TMPDIR/bin/pgrep"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# args: vdf since-epoch [token]
signed_in() {
  bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'
    if steam_signed_in '$1' '$LOGS' '${3:-/nonexistent}' '$2'; then echo \"yes: \$STEAM_SIGNIN_SIGNAL\"; else echo \"no: \$STEAM_SIGNIN_SIGNAL\"; fi"
}

@test "sign-in: the old account file with MostRecent counts" {
  signin_env
  run signed_in "$FIX/loginusers-old-mostrecent.vdf" 0
  [ "$output" = "yes: MostRecent in loginusers.vdf" ]
}

@test "sign-in: the new account file alone, with no logon in the log, does not count" {
  signin_env
  run signed_in "$FIX/loginusers-new-autologin.vdf" 0
  [[ $output == "no: "* ]]
}

@test "sign-in: the new account file plus a LogOnResponse OK since the start counts" {
  signin_env
  printf "[2026-10-31 19:19:00] [Logging On, 4, 2] [U:1:1] RecvMsgClientLogOnResponse() : [U:1:1] 'OK'\r\n" >"$LOGS/connection_log.txt"
  since=$(date -u -d '2026-10-31 19:00:00' +%s)
  run signed_in "$FIX/loginusers-new-autologin.vdf" "$since"
  [ "$output" = "yes: LogOnResponse 'OK' at 2026-10-31 19:19:00" ]
}

@test "sign-in: a logged-off state after LogOnResponse wins and names the reason" {
  signin_env
  cat >"$LOGS/connection_log.txt" <<'EOF'
[2026-11-03 01:00:00] [Logging On, 4, 2] [U:1:1] RecvMsgClientLogOnResponse() : [U:1:1] 'OK'
[2026-11-03 01:01:00] [Logged Off, 0, 0] [U:1:1] RecvMsgClientLoggedOff('Logged In Elsewhere')
EOF
  since=$(date -u -d '2026-11-03 00:00:00' +%s)
  run signed_in "$FIX/loginusers-old-mostrecent.vdf" "$since"
  [[ $output == "no: logged off: "*"Logged In Elsewhere"* ]]
}

@test "sign-in: one logged-off result restarts Steam only once" {
  marker="$BATS_TEST_TMPDIR/restarted" calls="$BATS_TEST_TMPDIR/restart.calls"
  run bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'
    restart_steam_client() { echo restart >>'$calls'; }
    restart_steam_after_logoff 'logged off: Logged In Elsewhere' '$marker'
    restart_steam_after_logoff 'logged off: Logged In Elsewhere' '$marker' || true"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$calls")" -eq 1 ]
}

@test "sign-in: a LogOnResponse OK from before this container start does not count" {
  signin_env
  printf "[2026-10-31 15:04:04] [Logging On, 4, 2] [U:1:1] RecvMsgClientLogOnResponse() : [U:1:1] 'OK'\r\n" >"$LOGS/connection_log.txt"
  since=$(date -u -d '2026-10-31 19:00:00' +%s)
  run signed_in "$FIX/loginusers-new-autologin.vdf" "$since"
  [[ $output == "no: "* ]]
}

@test "sign-in: a Logged On state from before this container start does not count" {
  # The previous container's "Logged On" line let the game launch
  # 20 s before the new client logged on, and SteamAPI failed to initialize.
  signin_env
  printf "[2026-10-31 15:04:04] [Logged On, 4, 2] [U:1:1] RecvMsgClientLogOnResponse() : processing complete\r\n" >"$LOGS/connection_log.txt"
  printf 'token\n' >"$BATS_TEST_TMPDIR/local.vdf"
  since=$(date -u -d '2026-10-31 19:00:00' +%s)
  STEAM_UP=1 run signed_in "$FIX/loginusers-new-autologin.vdf" "$since" "$BATS_TEST_TMPDIR/local.vdf"
  [[ $output == "no: "* ]]
}

@test "sign-in: token file and a logged-on running client count" {
  signin_env
  printf "[2026-10-31 19:04:04] [Logged On, 4, 2] [U:1:1] RecvMsgClientLogOnResponse() : processing complete\r\n" >"$LOGS/connection_log.txt"
  printf 'token\n' >"$BATS_TEST_TMPDIR/local.vdf"
  since=$(date -u -d '2026-10-31 19:00:00' +%s)
  STEAM_UP=1 run signed_in "$FIX/loginusers-new-autologin.vdf" "$since" "$BATS_TEST_TMPDIR/local.vdf"
  [ "$output" = "yes: token file and a logged-on client" ]
  STEAM_UP=0 run signed_in "$FIX/loginusers-new-autologin.vdf" "$since" "$BATS_TEST_TMPDIR/local.vdf"
  [[ $output == "no: "* ]]
}

@test "sign-in: an account that is not remembered never counts" {
  signin_env
  sed 's/"1"/"0"/' "$FIX/loginusers-old-mostrecent.vdf" >"$BATS_TEST_TMPDIR/forgot.vdf"
  run signed_in "$BATS_TEST_TMPDIR/forgot.vdf" 0
  [ "$output" = "no: no remembered account" ]
}

@test "say_on_change logs a line once, then only when it changes" {
  export SN2_STATE_DIR="$BATS_TEST_TMPDIR/state"
  run bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'
    for _ in 1 2 3; do say_on_change k 'starting the Windows Steam client'; done
    say_on_change k 'Windows Steam client running'
    say_on_change k 'Windows Steam client running'"
  [ "$(grep -c 'starting the Windows Steam client' <<<"$output")" -eq 1 ]
  [ "$(grep -c 'Windows Steam client running' <<<"$output")" -eq 1 ]
}

# ---- hands-free Steam install (steam-install-confirm.sh), stubbed xdotool ----

confirm_env() {
  export SN2_CONFIRM_LIB=1 CONFIRM_LOG="$BATS_TEST_TMPDIR/confirm.log"
  export STEAM_DIR="$BATS_TEST_TMPDIR/steam" GAME_APP_ID=1962700 DISPLAY=:99
  mkdir -p "$BATS_TEST_TMPDIR/stub" "$STEAM_DIR/steamapps"
  # Stub: windows come from $XDO_WINDOWS ("id|title" per line); presses are logged.
  cat >"$BATS_TEST_TMPDIR/stub/xdotool" <<'EOF'
#!/usr/bin/env bash
case $1 in
  search) cut -d'|' -f1 "$XDO_WINDOWS" ;;
  getwindowname) grep "^$2|" "$XDO_WINDOWS" | cut -d'|' -f2- ;;
  windowactivate) echo "activate $3" >>"$XDO_CALLS"; [ -z "${XDO_NO_WM:-}" ] ;;
  windowfocus) echo "focus $3" >>"$XDO_CALLS" ;;
  key) echo "key $3 $4" >>"$XDO_CALLS" ;;
  getwindowgeometry) printf 'WINDOW=%s\nX=370\nY=160\nWIDTH=540\nHEIGHT=480\n' "$3" ;;
  mousemove) echo "click $3 $4 $5" >>"$XDO_CALLS" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/stub/xdotool"
  export PATH="$BATS_TEST_TMPDIR/stub:$PATH"
  export XDO_WINDOWS="$BATS_TEST_TMPDIR/windows" XDO_CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$XDO_WINDOWS"; : >"$XDO_CALLS"
  # shellcheck source=/dev/null
  . "$BATS_TEST_DIRNAME/../scripts/steam-install-confirm.sh"
}

@test "install confirm: titles map to install, location and licence steps; others are ignored" {
  confirm_env
  [ "$(match_title 'Install - Subnautica 2')" = install ]
  [ "$(match_title 'Install')" = install ]
  [ "$(match_title 'Not enough disk space')" = location ]
  [ "$(match_title 'Choose location')" = location ]
  [ "$(match_title 'Subnautica 2 - License Agreement')" = eula ]
  run match_title 'Steam'; [ "$status" -ne 0 ]
  run match_title 'Sign in to Steam'; [ "$status" -ne 0 ]
  run match_title 'Friends List'; [ "$status" -ne 0 ]
  run match_title ''; [ "$status" -ne 0 ]
}

@test "install confirm: presses Enter on the install window and logs its title" {
  confirm_env
  printf '11|Steam\n42|Install - Subnautica 2\n' >"$XDO_WINDOWS"
  ATTEMPT=1 confirm_once
  grep -q '^activate 42$' "$XDO_CALLS"
  grep -q '^key 42 Return$' "$XDO_CALLS"
  [ "$(grep -c ' 11$' "$XDO_CALLS")" -eq 0 ]
  grep -q "attempt 1: pressed Enter on install window 'Install - Subnautica 2' (id 42)" "$CONFIRM_LOG"
}

@test "install confirm: with no window manager it focuses the window directly" {
  confirm_env
  export XDO_NO_WM=1
  printf '42|Install\n' >"$XDO_WINDOWS"
  ATTEMPT=1 confirm_once
  grep -q '^focus 42$' "$XDO_CALLS"
  grep -q '^key 42 Return$' "$XDO_CALLS"
}

@test "install confirm: a dialog still open after Enter gets one click on its primary button" {
  confirm_env
  printf '42|Install\n' >"$XDO_WINDOWS"
  ATTEMPT=1 confirm_once
  ATTEMPT=2 confirm_once
  grep -q '^click 42 210 436$' "$XDO_CALLS"
  grep -q "attempt 2: clicked the primary button of install window 'Install' (id 42)" "$CONFIRM_LOG"
}

@test "install confirm: retries until Steam writes the manifest, then stops" {
  confirm_env
  export CONFIRM_INTERVAL=0 CONFIRM_TIMEOUT=60
  m="$STEAM_DIR/steamapps/appmanifest_1962700.acf"
  printf '"AppState"\n{\n\t"UserConfig" { "BetaKey" "experimental" }\n}\n' >"$m"  # seeded, not taken
  # The window appears on the second look; Steam takes the install after the press.
  n=0
  sleep() { n=$((n + 1)); [ "$n" -eq 1 ] && echo '7|Install' >"$XDO_WINDOWS"; [ "$n" -eq 2 ] && echo '"StateFlags" "1026"' >>"$m"; return 0; }
  run confirm_loop
  [ "$status" -eq 0 ]
  grep -q "attempt 1: no install window on :99" "$CONFIRM_LOG"
  grep -q "attempt 2: pressed Enter on install window 'Install' (id 7)" "$CONFIRM_LOG"
  grep -q "attempt 3: manifest present; Steam took the install" "$CONFIRM_LOG"
}

@test "install confirm: gives up after the timeout and says the next start asks again" {
  confirm_env
  export CONFIRM_INTERVAL=0 CONFIRM_TIMEOUT=0
  run confirm_loop
  [ "$status" -eq 1 ]
  grep -q "attempt 1: no install window" "$CONFIRM_LOG"
  grep -q "gave up after 0s without a manifest; the next start asks again" "$CONFIRM_LOG"
}

@test "screenshot: needs exactly one file argument" {
  run env SN2_IN_CONTAINER=1 "$BATS_TEST_DIRNAME/../bin/moonpool" diag screenshot
  [ "$status" -ne 0 ]
  [[ $output == *"usage: moonpool diag screenshot <file.png>"* ]]
}

# ---- install wait: Steam's manifest flips to StateFlags 4 ------------------

install_env() {
  export SN2_STATE_DIR="$BATS_TEST_TMPDIR/state" GAME_APP_ID=1962700
  M="$BATS_TEST_TMPDIR/appmanifest_1962700.acf" CLOG="$BATS_TEST_TMPDIR/content_log.txt"
  EXE="$BATS_TEST_TMPDIR/Subnautica2-Win64-Shipping.exe"
  export M CLOG EXE
}

# The manifest and log while downloading (counters 0).
write_installing() {
  printf '"AppState"\n{\n\t"appid"\t\t"1962700"\n\t"StateFlags"\t\t"1026"\n\t"SizeOnDisk"\t\t"0"\n\t"BytesToDownload"\t\t"0"\n}\n' >"$M"
  printf '[2026-10-31 21:56:39] AppID 1962700 update started : download 0/14382468416, store 0/0, reuse 0/0, delta 0/0, stage 0/16425833908\n' >"$CLOG"
  printf '[2026-10-31 21:58:00] Current download rate: 212.400 Mbps\n' >>"$CLOG"
  : >"$EXE"   # Steam preallocates the executable; it must not count as installed
}

write_installed() {
  sed -i 's/"1026"/"4"/; s/"SizeOnDisk"\t\t"0"/"SizeOnDisk"\t\t"16425833908"/' "$M"
  printf '[2026-10-31 22:05:29] AppID 1962700 scheduler finished : removed from schedule (result No Error, state 0xc)\n' >>"$CLOG"
}

state_of() { bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; game_install_state '$M' '$CLOG' '$EXE'"; }

# The service's loop: every poll either reports progress or, once installed, launches.
poll() {
  bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'
    s=\$(game_install_state '$M' '$CLOG' '$EXE')
    if [ \"\$s\" != installed ]; then install_progress \"\$s\" '$CLOG'; exit 1; fi
    say_on_change install installed; say_on_change install launching"
}

@test "install state: a preallocated executable with StateFlags 1026 is still installing" {
  install_env; write_installing
  run state_of
  [ "$output" = "installing 14.4 GB" ]
}

@test "install state: StateFlags 4 after the scheduler finished is installed" {
  install_env; write_installing; write_installed
  run state_of
  [ "$output" = "installed" ]
}

@test "install state: no manifest is absent, or installed when the game folder was copied in" {
  install_env
  run state_of; [ "$output" = "absent" ]
  : >"$EXE"
  run state_of; [ "$output" = "installed" ]
}

@test "install state: StateFlags 4 while Steam's log says an update started is installing" {
  install_env; write_installing; write_installed
  printf '[2026-10-31 23:00:00] AppID 1962700 update started : download 0/2000000000, stage 0/2000000000\n' >>"$CLOG"
  run state_of
  [ "$output" = "installing 2.0 GB" ]
}

@test "install wait: polls a manifest that flips to 4 and logs installing, installed, launching once each" {
  install_env; write_installing
  out=""
  for _ in 1 2 3; do run poll; out+="$output"$'\n'; [ "$status" -eq 1 ]; done
  write_installed
  run poll; out+="$output"$'\n'; [ "$status" -eq 0 ]
  [ "$(grep -c 'installing 14.4 GB' <<<"$out")" -eq 1 ]
  [ "$(grep -c 'download: Current download rate: 212.400 Mbps' <<<"$out")" -eq 1 ]
  [ "$(grep -c ' installed$' <<<"$out")" -eq 1 ]
  [ "$(grep -c ' launching$' <<<"$out")" -eq 1 ]
  # order: installing, then installed, then launching
  [ "$(grep -nE 'installing 14.4|installed$|launching$' <<<"$out" | cut -d: -f2- | sed 's/.*\(installing\|installed\|launching\).*/\1/' | tr '\n' ' ')" = "installing installed launching " ]
}

# --- Executable follows STEAM_BRANCH ---------------------------------------

# Run common.sh's branch helpers against a fake Win64 folder holding the named executables.
branch_run() {
  local branch=$1; shift
  W="$BATS_TEST_TMPDIR/Win64"; mkdir -p "$W"
  for f in "$@"; do : >"$W/$f"; done
  STEAM_BRANCH="$branch" bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'
    echo \"exe=\$GAME_EXE_NAME\"; game_exe_mismatch '$W' && echo refuse || echo launch-ok"
}

@test "branch: public names the Shipping executable and launches it" {
  run branch_run public Subnautica2-Win64-Shipping.exe
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "exe=Subnautica2-Win64-Shipping.exe" ]
  [ "${lines[1]}" = "launch-ok" ]
}

@test "branch: experimental names the Test executable and launches it" {
  run branch_run experimental Subnautica2-Win64-Test.exe
  [ "${lines[0]}" = "exe=Subnautica2-Win64-Test.exe" ]
  [ "${lines[1]}" = "launch-ok" ]
}

@test "branch: unset STEAM_BRANCH means public" {
  run branch_run "" Subnautica2-Win64-Shipping.exe
  [ "${lines[0]}" = "exe=Subnautica2-Win64-Shipping.exe" ]
}

@test "branch: experimental over a public install prints the mismatch line and refuses" {
  run branch_run experimental Subnautica2-Win64-Shipping.exe
  [ "${lines[1]}" = "installed build is public, STEAM_BRANCH says experimental" ]
  [ "${lines[2]}" = "refuse" ]
}

@test "branch: public over an experimental install prints the mismatch line and refuses" {
  run branch_run public Subnautica2-Win64-Test.exe
  [ "${lines[1]}" = "installed build is experimental, STEAM_BRANCH says public" ]
  [ "${lines[2]}" = "refuse" ]
}

@test "branch: nothing installed is not a mismatch (the install path handles it)" {
  run branch_run public
  [ "${lines[1]}" = "launch-ok" ]
}

# --- UE4SS download: errors, retries, local fallback ------------------------

# A stub curl that fails until its call count reaches SUCCEED_ON, then writes PAYLOAD.
stub_curl() {
  B="$BATS_TEST_TMPDIR/bin"; mkdir -p "$B"
  cat >"$B/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$CURL_COUNT"
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
if [ "$n" -lt "$SUCCEED_ON" ]; then
  echo "curl: (6) Could not resolve host: github.com" >&2; printf '000'; exit 6
fi
printf '%s' "$PAYLOAD" >"$out"; printf '200'
EOF
  chmod +x "$B/curl"
  export PATH="$B:$PATH" CURL_COUNT="$BATS_TEST_TMPDIR/curl.count" PAYLOAD="pinned-zip-bytes"
  SHA=$(printf '%s' "$PAYLOAD" | sha256sum | cut -d' ' -f1)
  DEST="$BATS_TEST_TMPDIR/data/ue4ss/UE4SS_test.zip"; mkdir -p "${DEST%/*}"
}

fetch() {
  SN2_RETRY_PAUSE=0 bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'
    fetch_pinned 'https://example.invalid/UE4SS_test.zip' '$DEST' '$1'"
}

@test "fetch: fails twice, logs curl's own error each time, succeeds on the third try" {
  stub_curl; export SUCCEED_ON=3
  run fetch "$SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'curl exit 6, HTTP 000: curl: (6) Could not resolve host' <<<"$output")" -eq 2 ]
  [[ "$output" == *"downloaded https://example.invalid/UE4SS_test.zip (try 3)"* ]]
  [ "$(cat "$DEST")" = "pinned-zip-bytes" ]
  [ ! -e "$DEST.part" ]
}

@test "fetch: three failures give up and name the offline fallback path" {
  stub_curl; export SUCCEED_ON=9
  run fetch "$SHA"
  [ "$status" -eq 1 ]
  [ "$(cat "$CURL_COUNT")" -eq 3 ]
  [[ "$output" == *"put the file at $DEST"* ]]
  [ ! -e "$DEST" ]
}

@test "fetch: a local copy with the pinned SHA-256 is used without any download" {
  stub_curl; export SUCCEED_ON=9
  printf '%s' "$PAYLOAD" >"$DEST"
  run fetch "$SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using local copy $DEST (SHA-256 matches)"* ]]
  [ ! -e "$CURL_COUNT" ]
}

@test "fetch: a local copy with the wrong SHA-256 is set aside and downloaded again" {
  stub_curl; export SUCCEED_ON=1
  printf 'tampered' >"$DEST"
  run fetch "$SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved to $DEST.bad"* ]]
  [ "$(cat "$DEST")" = "pinned-zip-bytes" ]
}

@test "fetch: a download whose SHA-256 differs is refused" {
  stub_curl; export SUCCEED_ON=1
  run fetch 0000000000000000000000000000000000000000000000000000000000000000
  [ "$status" -eq 1 ]
  [ "$(grep -c 'downloaded file has SHA-256' <<<"$output")" -eq 3 ]
  [ ! -e "$DEST" ]
}

@test "restart: help says it recreates the container" {
  run "$CTL" help
  [[ "$output" == *"compose up -d --force-recreate"* ]]
}

# --- Launch precondition and crash backoff (scripts/common.sh) --------------
lib() { bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; $1"; }

full_win64() {
  W="$BATS_TEST_TMPDIR/Win64"
  mkdir -p "$W/ue4ss/UE4SS_Signatures"
  for s in FName_Constructor GNatives GUObjectHashTables StaticConstructObject; do
    echo "return 1" >"$W/ue4ss/UE4SS_Signatures/$s.lua"
  done
  echo "[x]" >"$W/ue4ss/MemberVariableLayout.ini"
  echo "[x]" >"$W/VTableLayout.ini"
  printf 'MajorVersion = 5\nMinorVersion = 6\n' >"$W/ue4ss/UE4SS-settings.ini"
  echo dll >"$W/dwmapi.dll"
}

# These hold the pinned channel's preconditions (auto picks it for a shipped build).
@test "precondition: a complete loader folder may load UE4SS" {
  full_win64
  run lib "UE4SS_CHANNEL=pinned; ue4ss_missing '$W'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "precondition: missing signatures and layouts hold the loader back" {
  full_win64
  rm "$W/ue4ss/UE4SS_Signatures/GNatives.lua" "$W/VTableLayout.ini"
  run lib "UE4SS_CHANNEL=pinned; ue4ss_missing '$W'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"signature:GNatives"* ]]
  [[ "$output" == *"VTableLayout.ini"* ]]
}

@test "precondition: settings that do not say 5.6 hold the loader back" {
  full_win64
  printf 'MajorVersion = 4\nMinorVersion =\n' >"$W/ue4ss/UE4SS-settings.ini"
  run lib "UE4SS_CHANNEL=pinned; ue4ss_missing '$W'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MajorVersion=5"* ]]
  [[ "$output" == *"MinorVersion=6"* ]]
}

@test "precondition: an empty layout file counts as missing" {
  full_win64
  : >"$W/ue4ss/MemberVariableLayout.ini"
  run lib "UE4SS_CHANNEL=pinned; ue4ss_missing '$W'"
  [ "$status" -eq 1 ]
  [[ "$output" == "MemberVariableLayout.ini" ]]
}

@test "backoff: quick crashes wait 30, 60, 120 ... capped at 600 s" {
  S="$BATS_TEST_TMPDIR/backoff"
  got=""
  for _ in 1 2 3 4 5 6 7; do got="$got $(lib "crash_backoff 12 '$S'")"; done
  [ "$got" = " 30 60 120 240 480 600 600" ]
}

@test "backoff: a run of 60 s or more resets it" {
  S="$BATS_TEST_TMPDIR/backoff"
  lib "crash_backoff 5 '$S'" >/dev/null
  lib "crash_backoff 5 '$S'" >/dev/null
  [ "$(lib "crash_backoff 3600 '$S'")" = 0 ]
  [ ! -f "$S" ]
  [ "$(lib "crash_backoff 5 '$S'")" = 30 ]
}

@test "install-confirm.log defaults to the data volume's logs folder" {
  run bash -c "unset CONFIRM_LOG LOG_DIR; DATA_DIR='$BATS_TEST_TMPDIR/d' SN2_CONFIRM_LIB=1 \
    bash -c 'source \"$BATS_TEST_DIRNAME/../scripts/steam-install-confirm.sh\" --lib-only 2>/dev/null; echo \"\$CONFIRM_LOG\"' | tail -1"
  [[ "$output" == "$BATS_TEST_TMPDIR/d/logs/install-confirm.log" ]]
  [ -d "$BATS_TEST_TMPDIR/d/logs" ]
}

# ---- the run folder follows DATA_DIR ---------------------------------------
# moonpool must take RUN_DIR from common.sh, as the service does, not /data/run.
stop_game_in_layout() {
  local data="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$data/control"  # the lock lives there; the container makes it at boot
  run env -u SN2_RUN_DIR -u SN2_CONTROL_DIR DATA_DIR="$data" SN2_IN_CONTAINER=1 \
    "$CTL" stop-game
  [ "$status" -eq 0 ]
  [[ $output == *"game stop requested"* ]]
  [ -f "$data/run/stopped" ]
  run env -u SN2_RUN_DIR -u SN2_CONTROL_DIR DATA_DIR="$data" SN2_IN_CONTAINER=1 \
    "$CTL" start-game
  [ "$status" -eq 0 ]
  [ ! -e "$data/run/stopped" ]
}

@test "stop-game writes the marker when DATA_DIR is /data" {
  stop_game_in_layout data
}

@test "stop-game writes the marker under the panel layout (DATA_DIR=/home/container shape)" {
  stop_game_in_layout home/container
}

@test "moonpool and the service read the same RUN_DIR from common.sh" {
  local data="$BATS_TEST_TMPDIR/home/container"
  svc=$(env DATA_DIR="$data" bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; echo \"\$RUN_DIR\"")
  ctl=$(env -u SN2_RUN_DIR DATA_DIR="$data" bash -c "$(declare -f mp); CTL='$CTL'; mp 'print(m.run_dir())'")
  [ "$svc" = "$data/run" ]
  [ "$ctl" = "$svc" ]
}

# A failed loader install holds UE4SS back with the install's own error.
c33() { env DATA_DIR="$1" bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; $2"; }

@test "a failed UE4SS install records its own error and holds the loader back" {
  d="$BATS_TEST_TMPDIR/d33"; mkdir -p "$d/w"
  run c33 "$d" "ue4ss_install_step sh -c 'echo downloading; echo \"[23:20:35] curl: (6) Could not resolve host: github.com\"; exit 3'"
  [ "$status" -eq 1 ]
  [ "$(cat "$d/run/ue4ss-install-failed")" = "curl: (6) Could not resolve host: github.com" ]
  run c33 "$d" "ue4ss_hold_reason '$d/w'"
  [ "$status" -eq 0 ]
  [ "$output" = "install failed: curl: (6) Could not resolve host: github.com" ]
  run c33 "$d" "ue4ss_install_step true"
  [ "$status" -eq 0 ]
  [ ! -e "$d/run/ue4ss-install-failed" ]
  run c33 "$d" "ue4ss_hold_reason '$d/w'"
  [[ "$output" == missing:* ]]
}

@test "the service launches after a failed UE4SS install instead of exiting" {
  svc="$BATS_TEST_DIRNAME/../docker/sn2-service.sh"
  run grep -c "UE4SS install failed; not launching" "$svc"
  [ "$output" = 0 ]
  grep -q 'ue4ss_install_step /opt/sn2/bin/install-ue4ss.sh' "$svc"
  grep -qF "Waiting for the loader: \$UE4SS_SERVES" "$BATS_TEST_DIRNAME/../scripts/launch-headless.sh"
}

# A surviving stop flag is logged at start and once an hour.
@test "a stop flag is logged once per start and then hourly" {
  d="$BATS_TEST_TMPDIR/d34"; mkdir -p "$d/run"; f="$d/run/stopped"; st="$d/run/stopped-noted"
  run c33 "$d" "stopped_notice '$f' '$st' 0"
  [ "$status" -eq 1 ] && [ -z "$output" ]
  TZ=UTC touch -t 202610312303.00 "$f"
  start=$(( $(date +%s) - 5 ))
  run c33 "$d" "stopped_notice '$f' '$st' $start"
  [ "$output" = "stopped by moonpool server stop at 2026-10-31 23:03 UTC; moonpool server start to run" ]
  run c33 "$d" "stopped_notice '$f' '$st' $start"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  echo $(( $(date +%s) - 3601 )) >"$st"
  run c33 "$d" "stopped_notice '$f' '$st' 0"
  [[ "$output" == "stopped by moonpool server stop at "* ]]
  echo $(( $(date +%s) - 60 )) >"$st"
  run c33 "$d" "stopped_notice '$f' '$st' $(( $(date +%s) + 1 ))"
  [[ "$output" == "stopped by moonpool server stop at "* ]]
  rm -f "$f"
  run c33 "$d" "stopped_notice '$f' '$st' 0"
  [ "$status" -eq 1 ] && [ ! -e "$st" ]
}

# The engine's own log is where each executable writes it (the public
# Shipping build's joins were only in the Wine user's AppData log).
@test "the game log is picked per executable" {
  d="$BATS_TEST_TMPDIR/uelog"; mkdir -p "$d"
  run c33 "$d" "USER=container; ue_log_for_exe Subnautica2-Win64-Shipping.exe"
  [ "$output" = "$d/wine/drive_c/users/container/AppData/Local/Subnautica2/Saved/Logs/Subnautica2.log" ]
  # A uid with no name: Wine's profile follows $USER, not id -un.
  run c33 "$d" "USER=container; id() { echo 988; }; ue_log_for_exe Subnautica2-Win64-Shipping.exe"
  [[ "$output" == */users/container/* ]]
  run c33 "$d" "GAME_DIR=/g; ue_log_for_exe Subnautica2-Win64-Test.exe"
  [ "$output" = "/g/Subnautica2/Saved/Logs/Subnautica2.log" ]
  run c33 "$d" "echo \$UE_LOG"
  [[ "$output" == */Subnautica2.log ]]
}

@test "the save folder is picked per executable" {
  d="$BATS_TEST_TMPDIR/savedir"; mkdir -p "$d"
  run c33 "$d" "USER=container; save_dir_for_exe Subnautica2-Win64-Shipping.exe"
  [ "$output" = "$d/wine/drive_c/users/container/AppData/Local/Subnautica2/Saved/SaveGames" ]
  run c33 "$d" "GAME_DIR=/g; save_dir_for_exe Subnautica2-Win64-Test.exe"
  [ "$output" = "/g/Subnautica2/Saved/SaveGames" ]
}

# The launcher reads the build id with common.sh's vdf_get; it once called a function
# only steam-config.sh defined, and every answer said game_build_id "unknown".
@test "vdf_get is common.sh's and reads the app manifest's buildid" {
  d="$BATS_TEST_TMPDIR/vdf"; mkdir -p "$d"
  printf '"AppState"\n{\n\t"appid"\t\t"1962700"\n\t"buildid"\t\t"25400633"\n}\n' >"$d/m.acf"
  run c33 "$d" "vdf_get '$d/m.acf' buildid"
  [ "$output" = 25400633 ]
  run c33 "$d" "vdf_get '$d/missing.acf' buildid"
  [ -z "$output" ]
  run ! grep -q '^vdf_get()' "$BATS_TEST_DIRNAME/../scripts/steam-config.sh"
}

# UE4SS_CHANNEL: which build installs and whether a shipped layout set is needed.
@test "UE4SS_CHANNEL pinned selects build 1188 and needs a layout set" {
  d="$BATS_TEST_TMPDIR/ch1"; mkdir -p "$d"
  run c33 "$d" "ue4ss_channel_select pinned"
  [ "$output" = "UE4SS_v3.0.1-1188-gf885e8d2.zip 4a594fb5c6e1aa794b06a770730e072c53fb92b741f95a5f0601080d80f4a6c1 no" ]
  run c33 "$d" "UE4SS_CHANNEL=pinned; ue4ss_needs_layout_set"
  [ "$status" -eq 0 ]
}

@test "UE4SS_CHANNEL upstream-experimental selects build 1190 and needs no layout set" {
  d="$BATS_TEST_TMPDIR/ch2"; mkdir -p "$d"
  run c33 "$d" "ue4ss_channel_select upstream-experimental"
  [ "$output" = "UE4SS_v3.0.1-1190-gf673aac0.zip 3ce35217fead1982e4563ef974364b7cfedf1dd6d28bb1193caf19877310364b yes" ]
  run c33 "$d" "UE4SS_CHANNEL=upstream-experimental; ue4ss_needs_layout_set"
  [ "$status" -eq 1 ]
}

# auto (the default): pinned for an executable a shipped set is for, else 1190.
@test "UE4SS_CHANNEL auto picks pinned for a shipped build and upstream-experimental otherwise" {
  d="$BATS_TEST_TMPDIR/auto"; w="$d/g/Subnautica2/Binaries/Win64"; mkdir -p "$w"
  printf build-a >"$w/Subnautica2-Win64-Shipping.exe"
  seed_set "$d/sets/a" a "$(sha256sum "$w/Subnautica2-Win64-Shipping.exe" | cut -d' ' -f1)"
  auto() { env -u UE4SS_CHANNEL DATA_DIR="$d/data" GAME_DIR="$d/g" STEAM_BRANCH=public UE4SS_LAYOUTS="$d/sets"     bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; ue4ss_channel; ue4ss_needs_layout_set && echo needs-layout"; }
  run auto
  [ "$output" = "$(printf 'pinned
needs-layout')" ]
  printf build-b >"$w/Subnautica2-Win64-Shipping.exe" # a game update: no set is for it
  run auto
  [ "$output" = upstream-experimental ]
}

@test "UE4SS_CHANNEL auto follows the install's answer; a set channel ignores it" {
  d="$BATS_TEST_TMPDIR/autofile"; mkdir -p "$d/run"
  echo pinned >"$d/run/ue4ss-channel"
  run c33 "$d" "unset UE4SS_CHANNEL; ue4ss_channel"
  [ "$output" = pinned ]
  run c33 "$d" "UE4SS_CHANNEL=upstream-experimental; ue4ss_channel"
  [ "$output" = upstream-experimental ]
  echo junk >"$d/run/ue4ss-channel" # no exe here either: the build without a set
  run c33 "$d" "UE4SS_CHANNEL=auto; ue4ss_channel"
  [ "$output" = upstream-experimental ]
}

@test "the install resolves auto, keeps the answer and names it" {
  f="$BATS_TEST_DIRNAME/../scripts/install-ue4ss.sh"
  # shellcheck disable=SC2016  # literal text in the script
  grep -q 'UE4SS_CHANNEL="${UE4SS_CHANNEL:-auto}"' "$f"
  # shellcheck disable=SC2016  # literal text in the script
  grep -q 'echo "$UE4SS_CHANNEL" >"$UE4SS_CHANNEL_FILE"' "$f"
  grep -q 'UE4SS_CHANNEL=auto picked' "$f"
}

@test "an unknown UE4SS_CHANNEL is refused by name" {
  d="$BATS_TEST_TMPDIR/ch3"; mkdir -p "$d"
  run c33 "$d" "ue4ss_channel_select beacon 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not 'beacon'"* ]]
}

@test "a hand-set asset and hash override the channel's pin" {
  d="$BATS_TEST_TMPDIR/ch4"; mkdir -p "$d"
  run c33 "$d" "UE4SS_ASSET=x.zip UE4SS_RELEASE_SHA256=abc ue4ss_channel_select upstream-experimental"
  [ "$output" = "x.zip abc yes" ]
}

@test "upstream-experimental does not hold the loader back for missing patterns or layouts" {
  d="$BATS_TEST_TMPDIR/ch5"; w="$d/w"; mkdir -p "$w/ue4ss"
  : >"$w/dwmapi.dll"; : >"$w/ue4ss/UE4SS.dll"
  run c33 "$d" "UE4SS_CHANNEL=pinned; ue4ss_missing '$w'"
  [[ "$output" == *"signature:GNatives"* ]] && [[ "$output" == *"MemberVariableLayout.ini"* ]]
  run c33 "$d" "UE4SS_CHANNEL=upstream-experimental; ue4ss_missing '$w'"
  [[ "$output" != *"signature:"* ]] && [[ "$output" != *"Layout.ini"* ]]
}

@test "held-back line reaches services.log" {
  # shellcheck disable=SC2016 # the literal text in the launcher
  grep -q 'tee -a "$LOG_DIR/services.log"' "$BATS_TEST_DIRNAME/../scripts/launch-headless.sh"
}

# Operator layout sets: a set is picked only
# when the FULL sha256 stored in its exe.sha256 is the running exe's; anything
# else fails closed and the game starts without the loader.
layout_env() {
  export WIN64_DIR="$BATS_TEST_TMPDIR/win64" UE4SS_DIR="$BATS_TEST_TMPDIR/win64/ue4ss"
  export UE4SS_LAYOUTS="$BATS_TEST_TMPDIR/shipped" UE4SS_NO_LAYOUT_FILE="$BATS_TEST_TMPDIR/run/ue4ss-no-layout"
  mkdir -p "$WIN64_DIR" "$UE4SS_DIR"
  printf 'build-a' >"$WIN64_DIR/Game.exe"
  SHA=$(sha256sum "$WIN64_DIR/Game.exe" | cut -d' ' -f1)
  log() { echo "$*"; }
  eval "$(sed -n '/^LAYOUT_FILES=/,/^}/p' "$BATS_TEST_DIRNAME/../scripts/common.sh")"
  # shellcheck disable=SC2016  # the sed range is a literal match on the script's text
  eval "$(sed -n '/^# The settings into the ue4ss folder/,/^\[ -d "\$WIN64_DIR" \]/p' "$BATS_TEST_DIRNAME/../scripts/install-ue4ss.sh" | sed '$d')"
}
seed_set() { # dir label sha
  mkdir -p "$1"
  for f in MemberVariableLayout.ini VTableLayout.ini UE4SS-settings.ini; do echo "$2 $f" >"$1/$f"; done
  echo "$3" >"$1/exe.sha256"
}

@test "layout: a set's signatures replace whatever an earlier set left" {
  layout_env
  seed_set "$UE4SS_LAYOUTS/any-label" shipped "$SHA"
  mkdir -p "$UE4SS_LAYOUTS/any-label/UE4SS_Signatures" "$UE4SS_DIR/UE4SS_Signatures"
  echo new >"$UE4SS_LAYOUTS/any-label/UE4SS_Signatures/GNatives.lua"
  echo old >"$UE4SS_DIR/UE4SS_Signatures/Stale.lua"
  run pick_layout "$SHA"
  [ "$status" -eq 0 ]
  [ "$(cat "$UE4SS_DIR/UE4SS_Signatures/GNatives.lua")" = new ]
  [ ! -e "$UE4SS_DIR/UE4SS_Signatures/Stale.lua" ]
}

@test "layout: the set whose exe.sha256 is this exe's full hash is applied" {
  layout_env
  seed_set "$UE4SS_LAYOUTS/any-label" shipped "$SHA"
  run pick_layout "$SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UE4SS layout: operator set any-label (exe sha256 $SHA)"* ]]
  grep -q 'shipped MemberVariableLayout.ini' "$WIN64_DIR/MemberVariableLayout.ini"
  grep -q 'shipped VTableLayout.ini' "$UE4SS_DIR/VTableLayout.ini"
  grep -q 'shipped UE4SS-settings.ini' "$UE4SS_DIR/UE4SS-settings.ini"
  [ ! -e "$UE4SS_NO_LAYOUT_FILE" ]
}

@test "layout: a set for another exe is refused, even with the same 8-char prefix" {
  layout_env
  seed_set "$UE4SS_LAYOUTS/${SHA:0:8}" other "${SHA:0:8}$(printf '0%.0s' $(seq 56))"
  echo stale >"$WIN64_DIR/VTableLayout.ini"
  run pick_layout "$SHA"
  [ "$status" -eq 1 ]
  [ "$output" = "no layout set in $UE4SS_LAYOUTS for this build $SHA; set UE4SS_CHANNEL=auto (build 1190 needs none)" ]
  [ "$(cat "$UE4SS_NO_LAYOUT_FILE")" = "$SHA" ]
  [ ! -e "$WIN64_DIR/VTableLayout.ini" ]
}

@test "layout: a set without exe.sha256 is never used" {
  layout_env
  seed_set "$UE4SS_LAYOUTS/x" shipped "$SHA"
  rm "$UE4SS_LAYOUTS/x/exe.sha256"
  run pick_layout "$SHA"
  [ "$status" -eq 1 ]
}

@test "layout: no set held back the loader and the launcher says why" {
  d="$BATS_TEST_TMPDIR/nl"; w="$d/g/Subnautica2/Binaries/Win64"; mkdir -p "$w/ue4ss" "$d/data/run"
  : >"$w/dwmapi.dll"; : >"$w/ue4ss/UE4SS.dll"
  echo deadbeef >"$d/data/run/ue4ss-no-layout"
  run env DATA_DIR="$d/data" GAME_DIR="$d/g" UE4SS_CHANNEL=pinned bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; ue4ss_launch_mode '$w'"
  [[ "$output" == "held "*"no known-good layout for this build deadbeef"* ]]
}

# --- Launch: xaudio2 off, arm on every launch, no recreate under a session ---
@test "launch: the game line's DLL overrides end with xaudio2_9=d in every mode" {
  run bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; echo \"\$GAME_DLL_EXTRA\""
  [ "$output" = "xaudio2_9=d" ]
  # One export, after every mode branch has built its overrides.
  # shellcheck disable=SC2016  # the literal line text is what is searched for
  run grep -c '^export WINEDLLOVERRIDES="${overrides};${GAME_DLL_EXTRA}"$' \
    "$BATS_TEST_DIRNAME/../scripts/launch-headless.sh"
  [ "$output" = "1" ]
  run grep -c 'WINEDLLOVERRIDES=' "$BATS_TEST_DIRNAME/../scripts/launch-headless.sh"
  [ "$output" = "1" ]
}

@test "launch: the service writes HOST_ARMED on every launch, not only when absent" {
  run grep -n 'HOST_ARMED_FILE" \]; then' "$BATS_TEST_DIRNAME/../docker/sn2-service.sh"
  [ "$status" -ne 0 ]
  # shellcheck disable=SC2016  # the literal line text is what is searched for
  run grep -c ': >"$HOST_ARMED_FILE"' "$BATS_TEST_DIRNAME/../docker/sn2-service.sh"
  [ "$output" -ge 1 ]
}

@test "launch: previous game and UE4SS logs are paired and only 30 launches remain" {
  local root="$BATS_TEST_TMPDIR/history" game="$BATS_TEST_TMPDIR/Subnautica2.log"
  local mod="$BATS_TEST_TMPDIR/UE4SS.log"
  printf game >"$game"; printf mod >"$mod"
  for n in $(seq -w 1 31); do
    run bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; archive_previous_logs '$root' '$game' '$mod' '20261103T0000${n}Z'"
    [ "$status" -eq 0 ]
  done
  [ "$(find "$root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 30 ]
  [ ! -d "$root/20261103T000001Z" ]
  cmp "$game" "$root/20261103T000031Z/game.log"
  cmp "$mod" "$root/20261103T000031Z/UE4SS.log"
}

session_files() {
  echo "{\"hosted\":$1}" >"$SN2_CONTROL_DIR/readiness.json"
  echo "{\"players\":$2}" >"$SN2_CONTROL_DIR/status.json"
}

session_up() { bash -c ". '$BATS_TEST_DIRNAME/../scripts/common.sh'; CONTROL_DIR='$SN2_CONTROL_DIR' session_up"; }

@test "session_up: true only when hosted with a player other than the host" {
  # The host is whoever HOST_NAME names; pin it so a caller's .env cannot leak in.
  export HOST_NAME="SN2 Host"
  session_files true '[{"name":"SN2 Host"},{"name":"Ada"}]'
  run session_up
  [ "$status" -eq 0 ]
  # Hosted (Host call ok, session created) with nobody joined yet: not up.
  session_files true '[{"name":"SN2 Host"}]'
  run session_up
  [ "$status" -ne 0 ]
  session_files false '[{"name":"Ada"}]'
  run session_up
  [ "$status" -ne 0 ]
  # A renamed host is still the host, not a player.
  export HOST_NAME="Reef Keeper"
  session_files true '[{"name":"Reef Keeper"}]'
  run session_up
  [ "$status" -ne 0 ]
  session_files true '[{"name":"Reef Keeper"},{"name":"Ada"}]'
  run session_up
  [ "$status" -eq 0 ]
}

@test "restart: warns a live session, and --now skips the warning" {
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  # A fake docker: every call is recorded and succeeds.
  cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/docker.calls"
EOF
  chmod +x "$stub/docker"
  run env -u SN2_IN_CONTAINER PATH="$stub:$PATH" "$CTL" server restart
  [ "$status" -eq 0 ]
  grep -q -- 'restart-warning container restarting' "$BATS_TEST_TMPDIR/docker.calls"
  grep -q -- '--force-recreate' "$BATS_TEST_TMPDIR/docker.calls"
  rm "$BATS_TEST_TMPDIR/docker.calls"
  run env -u SN2_IN_CONTAINER PATH="$stub:$PATH" "$CTL" server restart --now
  grep -q -- '--force-recreate' "$BATS_TEST_TMPDIR/docker.calls"
  run grep -q -- 'restart-warning' "$BATS_TEST_TMPDIR/docker.calls"
  [ "$status" -ne 0 ]
}

# ---- the "how to join" welcome card ----------------------------------------
# Every source present: the branch (STEAM_BRANCH), the account in Steam's own
# loginusers.vdf, the build in the app manifest, the Sonar code in status.json.
welcome_env() {
  policy_env
  export STEAM_BRANCH=experimental HOST_NAME="Reef Keeper" GAME_APP_ID=1962700
  export WINEPREFIX="$BATS_TEST_TMPDIR/wine"
  local s="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
  mkdir -p "$s/config" "$s/steamapps"
  printf '"users"\n{\n\t"76561197960266728"\n\t{\n\t\t"AccountName"\t"host"\n\t}\n}\n' \
    >"$s/config/loginusers.vdf"
  printf '"AppState"\n{\n\t"buildid"\t\t"20511234"\n}\n' >"$s/steamapps/appmanifest_1962700.acf"
  echo '{"players":[],"sonar_code":"ABCD-1234"}' >"$CONTROL_DIR/status.json"
}
# A stub Discord: answers every call 200, a create with a message id, and records
# each method and path so a test can see a create and then an edit in place.
stub_discord() {
  FAKE="$BATS_TEST_TMPDIR/fake-discord"; mkdir -p "$FAKE/peer"
  FAKE_DISCORD_CARD_ID=1300000000000000042 python3 "$BATS_TEST_DIRNAME/fake_discord.py" "$FAKE" >/dev/null 2>&1 &
  FAKE_PID=$!
  for _ in $(seq 1 50); do [ -s "$FAKE/port" ] && break; sleep 0.1; done
  export DISCORD_CALLS="$FAKE/calls" DISCORD_BODIES="$FAKE/bodies"
  local port; port=$(cat "$FAKE/port")
  export DISCORD_WEBHOOK_URL="http://127.0.0.1:$port/api/webhooks/1/token"
}

@test "one card contains state world players and every available join path" {
  command -v jq >/dev/null || skip "jq not installed"
  welcome_env
  mkdir -p "$DATA_DIR/public"
  echo '{"world_name":"Deep Blue","players":[{"name":"Reef Keeper"},{"name":"Alice"}],"sonar_code":"ABCD-1234"}' \
    >"$CONTROL_DIR/status.json"
  printf up >"$DATA_DIR/discord/override"; printf 9999999999 >"$DATA_DIR/discord/override.expires"
  body=$(SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example python3 "$DN" --dry-run status | grep '^{')
  # Components V2 (1<<15) and silent (1<<12), mentions parsed from nothing.
  [ "$(jq -r '.flags' <<<"$body")" = 36864 ]
  [ "$(jq -c '.allowed_mentions' <<<"$body")" = '{"parse":[]}' ]
  card=$(jq -c '.components[0]' <<<"$body")
  head=$(jq -r '.components[0].components[0].content' <<<"$card")
  [[ $head == '## 🌊 Deep Blue'$'\n''🟢 **Open** since <t:1700000000:R> · **1** aboard'* ]]
  [[ $card != *"hosted by"* ]]
  [[ $card == *"• Alice"* ]]
  [[ $card == *"steamcommunity.com/profiles/76561197960266728"* ]]
  [[ $card == *"add **Reef Keeper**"* && $card == *"code **1000**"* && $card == *"**Xbox** add code **ABCD-1234**"* ]]
  [[ $card != *"How to join"* ]]
  [[ $body != *"Sonar"* ]]
  # The steps sit once under every world, so a board of two doesn't repeat them.
  [ "$(jq -r '.components | length' <<<"$body")" -eq 2 ]
  how=$(jq -r '.components[-1].content' <<<"$body")
  [[ $how == *"How to join"* && $how == *"Press **Join**"* && $how == *"Join Game"* ]]
  [[ $how == *"Xbox / PC Game Pass"* && $how == *"background audio"* ]]
  [[ $how == *"not affiliated with Unknown Worlds, KRAFTON or Valve"* ]]
  # Without the switch nobody is accepted automatically; with it, only invited players unless anyone may ask.
  [[ $how == *"the host accepts it by hand"* ]]
  body=$(AUTO_ACCEPT_FRIENDS=1 SN2_NOW=1700000000 python3 "$DN" --dry-run status | grep '^{')
  [[ $(jq -r '.components[-1].content' <<<"$body") == *"an admin has to invite you first"* ]]
  body=$(ALLOWLIST_ONLY=false AUTO_ACCEPT_FRIENDS=1 SN2_NOW=1700000000 python3 "$DN" --dry-run status | grep '^{')
  [[ $(jq -r '.components[-1].content' <<<"$body") == *"it accepts within a minute"* ]]
}

@test "one card respects hidden names and never publishes player positions" {
  command -v jq >/dev/null || skip "jq not installed"
  welcome_env
  echo '{"players":[{"name":"Alice","x":12,"y":34,"depth_m":56},{"name":"Bob","x":78,"y":90}]}' \
    >"$CONTROL_DIR/status.json"
  body=$(SHOW_PLAYER_NAMES=false python3 "$DN" --dry-run status | grep '^{')
  aboard=$(jq -r '.components[0].components[] | select(.type == 10) | .content | select(startswith("**Aboard**"))' <<<"$body")
  [[ $aboard == *$'• Player 1\n• Player 2'* ]]
  [[ $body != *Alice* && $body != *Bob* ]]
  [[ $body != *depth* && $body != *mapgenie* && $body != *'"x"'* ]]
}

@test "one card names all four states and gives each a since time" {
  command -v jq >/dev/null || skip "jq not installed"
  welcome_env
  for state in up starting updating down; do
    printf '%s' "$state" >"$DATA_DIR/discord/override"
    printf 9999999999 >"$DATA_DIR/discord/override.expires"
    body=$(SN2_NOW=1700000000 python3 "$DN" --dry-run status | grep '^{')
    head=$(jq -r '.components[0].components[0] | (.content // .components[0].content)' <<<"$body")
    case $state in up) word=Open ;; starting) word=Starting ;; updating) word=Updating ;; *) word=Down ;; esac
    [[ $head == *"**$word** since <t:1700000000:R>"* ]]
  done
}

@test "routine events only refresh the silent card and never post an event line" {
  command -v jq >/dev/null || skip "jq not installed"
  welcome_env
  for event in join leave backup_failed up; do
    run python3 "$DN" --dry-run event "$event" Alice
    [ "$status" -eq 0 ]
    [ "$(grep -c '^POST ' <<<"$output")" -le 1 ]
    body=$(grep '^{' <<<"$output")
    [ "$(jq -r '.flags' <<<"$body")" = 36864 ]
    [[ $body != *"joined"* && $body != *"left"* && $body != *"backup failed"* ]]
  done
}

@test "restart update and outage alone mention the configured role; silent unless pushes are asked for" {
  command -v jq >/dev/null || skip "jq not installed"
  welcome_env
  for event in restart update outage; do
    run env DISCORD_ALERT_ROLE_ID=123456789 SN2_NOW=1700000000 python3 "$DN" --dry-run event "$event" detail
    [ "$status" -eq 0 ]
    alert=$(grep '^{' <<<"$output" | head -1)
    # <@&id> is a role mention; <@id> would name a user and ping nobody. (The old check here
    # sat in an `a || { b && c; }` list, which errexit never enforces, so it checked nothing.)
    case $event in restart) said=restarting ;; *) said=$event ;; esac
    [ "$(jq -r .content <<<"$alert")" = "<@&123456789> Reef Keeper: $said — detail" ]
    [ "$(jq -c '.allowed_mentions' <<<"$alert")" = '{"parse":[],"roles":["123456789"]}' ]
    # Silent by default (shown, no push), like the card: a night of restarts wakes nobody.
    [ "$(jq -r '.flags' <<<"$alert")" = 4096 ]
    card=$(grep '^{' <<<"$output" | tail -1)
    [ "$(jq -r .flags <<<"$card")" = 36864 ]
    run env DISCORD_ALERT_ROLE_ID=123456789 DISCORD_ALERTS_NOTIFY=true SN2_NOW=1700000000 \
      python3 "$DN" --dry-run event "$event" detail
    [ "$status" -eq 0 ]
    alert=$(grep '^{' <<<"$output" | head -1)
    [ "$(jq -r '.flags' <<<"$alert")" = 0 ]
  done
  run python3 "$DN" --dry-run event chat hello
  [ "$status" -eq 65 ]
  run env -u DISCORD_ALERT_ROLE_ID python3 "$DN" --dry-run event outage detail
  alert=$(grep '^{' <<<"$output" | head -1)
  [ "$(jq -c '.allowed_mentions' <<<"$alert")" = '{"parse":[]}' ]
  [[ $(jq -r .content <<<"$alert") != *'<@'* ]]
}

@test "local webhook sees one create then edits it and recreates only after 404" {
  command -v jq >/dev/null || skip "jq not installed"
  welcome_env; stub_discord
  run python3 "$DN" status
  [ "$status" -eq 0 ]
  [ "$(cat "$DATA_DIR/discord/card.id")" = 1300000000000000042 ]
  grep -q '^POST .*?wait=true&with_components=true$' "$DISCORD_CALLS"
  rm -f "$DATA_DIR/discord/card.sum"
  echo '{"players":[],"sonar_code":"WXYZ-9876"}' >"$CONTROL_DIR/status.json"
  run python3 "$DN" status
  [ "$(grep -c '^POST' "$DISCORD_CALLS")" -eq 1 ]
  grep -q '^PATCH .*/messages/1300000000000000042?with_components=true$' "$DISCORD_CALLS"
  rm -f "$DATA_DIR/discord/card.sum"
  : >"$FAKE/patch-404"
  run python3 "$DN" status
  kill "$FAKE_PID" 2>/dev/null || true
  [ "$(grep -c '^POST' "$DISCORD_CALLS")" -eq 2 ]
  grep -q 'card was deleted; recreating it' "$LOG_DIR/discord.log"
}

@test "settings: moonpool settings apply queues the command only when settings.yaml is installed" {
  run "$CTL" settings
  [ "$status" -ne 0 ]
  [[ $output == *"usage: moonpool settings apply"* ]]
  run "$CTL" settings apply
  [ "$status" -ne 0 ]
  [[ $output == *"no settings.yaml"* ]]
  printf 'weather: clear\nmods: []\n' >"$SN2_CONTROL_DIR/settings.yaml"
  fake_mod true
  run "$CTL" settings apply
  wait
  [ "$status" -eq 0 ]
  [[ $output == *'"cmd":"settings"'* ]]
}

# ---- the --json envelope and the exit matrix ---------------------------------
# One object on stdout and nothing on stderr (run merges both: one line), with
# every field, and the exit code of the table in usage.
envelope() {
  [ "${#lines[@]}" -eq 1 ]
  jq -e '.schema_version == 1 and (.request_id | test("^[0-9a-f]{32}$")) and (.command | type) == "string"
    and (.ok | type) == "boolean" and (.state | type) == "string" and (.code | type) == "string"
    and (.message | type) == "string" and ((.next_action | type) == "string" or .next_action == null)
    and (.data | type) == "object" and (.started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    and (.completed_at | type) == "string" and (.duration_ms | type) == "number"' <<<"$output" >/dev/null
}
field() { jq -r ".$1" <<<"$output"; }
# verdict CODE STATE EXIT OK: the four that must agree.
verdict() {
  [ "$status" -eq "$3" ]
  [ "$(field code)" = "$1" ]
  [ "$(field state)" = "$2" ]
  [ "$(field ok)" = "$4" ]
}

@test "json: a success is verified/ok/0 with the mod's data; --json goes before or after the command" {
  fake_mod true '{"players":[{"name":"Ada"}]}'
  run "$CTL" --json players
  wait
  envelope; verdict ok verified 0 true
  [ "$(field command)" = players ]
  [ "$(field 'data.players[0].name')" = Ada ]
  [ "$(field next_action)" = null ]
  # the queue request carried the envelope's request id
  grep -q "\"id\":\"$(field request_id)\"" "$SN2_CONTROL_DIR/receipts/request.json"
  fake_mod true
  run "$CTL" players --json
  wait
  envelope; verdict ok verified 0 true
}

@test "json: a queued answer is submitted/accepted/0 and says the effect is not read back" {
  fake_mod true '{"queued":true}'
  run "$CTL" --json diag console Ada Heal
  wait
  envelope; verdict accepted submitted 0 true
  [ "$(field command)" = diag.console ]
  [ "$(field data.queued)" = true ]
  [[ $(field message) == *"not read back"* ]]
}

@test "json: the mod's refusal is refused/refused/77 with its error kept under data.protocol_error" {
  fake_mod false unknown_player
  run "$CTL" --json players kick Nobody
  wait
  envelope; verdict refused refused 77 false
  [ "$(field command)" = players.kick ]
  [ "$(field data.protocol_error)" = unknown_player ]
}

@test "json: a bad argument is refused/invalid_argument/64 and queues nothing" {
  run "$CTL" --json server slots 99
  envelope; verdict invalid_argument refused 64 false
  [ "$(field command)" = server.slots ]
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
}

@test "json: no answer is failed/timeout/75 with a next action, and the request is withdrawn" {
  SN2_TIMEOUT=1 run "$CTL" --json players
  envelope; verdict timeout failed 75 false
  [[ $(field next_action) == *"do not resubmit"* ]]
  [ -z "$(ls "$SN2_CONTROL_DIR"/inbox/*.json 2>/dev/null)" ]
}

@test "json: an answer that is not JSON, or lacks the {ok, data, error} contract, is failed/protocol_error/70" {
  fake_mod raw 'not json at all'
  run "$CTL" --json players
  wait
  envelope; verdict protocol_error failed 70 false
  [ "$(field data.protocol_error)" = "not JSON or not UTF-8" ]
  fake_mod raw '{"v":1,"id":"x","ok":true}'
  run "$CTL" --json players
  wait
  envelope; verdict protocol_error failed 70 false
  [[ $(field message) == *"data is not an object"* ]] || [[ $(field message) == *"not the request id"* ]] ||
    [[ $(field message) == *"does not accept protocol version"* ]]
}

@test "json: an answer under another request id is failed/protocol_error/70" {
  FAKE_REPLY_ID=00000000000000000000000000000000 fake_mod true
  run "$CTL" --json players
  wait
  envelope; verdict protocol_error failed 70 false
  [[ $(field message) == *"not the request id"* ]]
}

@test "json: an unknown command is invalid_argument/64 and save returns the mod's answer" {
  run "$CTL" --json frobnicate
  envelope; verdict invalid_argument refused 64 false
  [ "$(field command)" = unknown ]
  fake_mod true '{"forced":true,"queued":true}'
  run "$CTL" --json server save; wait
  envelope; verdict accepted submitted 0 true
  [ "$(field command)" = server.save ]
  [ "$(field data.forced)" = true ]
}

@test "json: a given SN2_REQUEST_ID is the envelope's and the queue's id; a malformed one is refused" {
  fake_mod true
  SN2_REQUEST_ID=0123456789abcdef0123456789abcdef run "$CTL" --json players
  wait
  envelope; verdict ok verified 0 true
  [ "$(field request_id)" = 0123456789abcdef0123456789abcdef ]
  grep -q '"id":"0123456789abcdef0123456789abcdef"' "$SN2_CONTROL_DIR/receipts/request.json"
  SN2_REQUEST_ID=short run "$CTL" --json players
  envelope; verdict invalid_argument refused 64 false
}

@test "json: the prose mode keeps its surface and exits by the same table" {
  fake_mod false
  run "$CTL" players kick Nobody
  wait
  [ "$status" -eq 77 ]
  [[ $output == *'"ok":false'* ]]
  [[ $output == *"refused by the mod: no connected player has that name (unknown_player)"* ]]
  run "$CTL" server slots 99
  [ "$status" -eq 64 ]
}

# A fake docker for the host-side copy: compose ps names a running container
# (none when STUB_DOWN=1), inspect says it runs, and compose exec runs the
# container copy of moonpool right here with the -e variables it was given.
docker_stub() {
  stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
  cat >"$stub/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/docker.calls"
case "\$1 \$2" in
  "compose version") exit 0 ;;
  "compose ps") [ -n "\${STUB_DOWN:-}" ] || echo cafe0000cafe; exit 0 ;;
  "compose cp") case "\$3" in sn2:*) cp "\${3#sn2:}" "\$4" ;; *) cp "\$3" "\${4#sn2:}" ;; esac; exit 0 ;;
  "inspect "*) echo true; exit 0 ;;
  "compose exec")
    shift 2; envs=()
    while [ "\$1" != sn2 ]; do case \$1 in -e) envs+=("\$2"); shift ;; esac; shift; done
    shift 2
    exec env "\${envs[@]}" SN2_IN_CONTAINER=1 "$CTL" "\$@" ;;
esac
EOF
  chmod +x "$stub/docker"
}

@test "json: the host copy makes one request id and forwards it and --json into the container" {
  docker_stub
  fake_mod true
  run env -u SN2_IN_CONTAINER PATH="$stub:$PATH" "$CTL" players --json
  wait
  envelope; verdict ok verified 0 true
  rid=$(field request_id)
  grep -q "\"id\":\"$rid\"" "$SN2_CONTROL_DIR/receipts/request.json"
  grep -Eq "compose exec -T -e SN2_REQUEST_ID=$rid -e SN2_STARTED_AT=[0-9TZ:-]+ -e SN2_START_MS=[0-9]+ sn2 moonpool --json players" "$BATS_TEST_TMPDIR/docker.calls"
}

@test "json: a container that is not running is failed/unavailable/69 from the host copy" {
  docker_stub
  run env -u SN2_IN_CONTAINER STUB_DOWN=1 PATH="$stub:$PATH" "$CTL" --json players
  envelope; verdict unavailable failed 69 false
  [[ $(field message) == *"not running"* ]]
  run env -u SN2_IN_CONTAINER STUB_DOWN=1 PATH="$stub:$PATH" "$CTL" players
  [ "$status" -eq 69 ]
}

# ---- the one lock -------------------------------------------------------------
# A mutating command runs under control/moonpool.lock; a read-only one does not.
@test "lock: a second mutation while one runs is refused 77 with the retry action" {
  FAKE_DELAY=2 fake_mod true
  "$CTL" --json server slots 8 >"$BATS_TEST_TMPDIR/first.json" &
  sleep 0.5
  SN2_LOCK_WAIT=1 run "$CTL" --json server arm
  envelope; verdict refused refused 77 false
  [ "$(field next_action)" = "Retry after the current operation completes." ]
  [ ! -e "$SN2_CONTROL_DIR/HOST_ARMED" ]
  wait
  jq -e '.ok == true and .command == "server.slots"' "$BATS_TEST_TMPDIR/first.json" >/dev/null
}

@test "lock: concurrent mutations serialize, each under its own request id" {
  # Two slow answers in parallel: serialized, the second request is claimed only after
  # the first is answered (the fakes' own log; wall time is not evidence here).
  FAKE_DELAY=1 fake_mod true
  FAKE_DELAY=1 fake_mod true
  "$CTL" --json server slots 8 >"$BATS_TEST_TMPDIR/a.json" &
  "$CTL" --json server slots 7 >"$BATS_TEST_TMPDIR/b.json" &
  wait
  log="$SN2_CONTROL_DIR/fake.log"
  [ "$(grep -c ' claim ' "$log")" -eq 2 ] && [ "$(grep -c ' answer ' "$log")" -eq 2 ]
  first_answer=$(grep ' answer ' "$log" | sort -n | head -1 | cut -d' ' -f1)
  second_claim=$(grep ' claim ' "$log" | sort -n | tail -1 | cut -d' ' -f1)
  awk -v a="$first_answer" -v c="$second_claim" 'BEGIN { exit !(c >= a) }'
  jq -e '.ok == true' "$BATS_TEST_TMPDIR/a.json" >/dev/null
  jq -e '.ok == true' "$BATS_TEST_TMPDIR/b.json" >/dev/null
  [ "$(jq -r .request_id "$BATS_TEST_TMPDIR/a.json")" != "$(jq -r .request_id "$BATS_TEST_TMPDIR/b.json")" ]
}

@test "lock: SN2_LOCK_HELD=1 counts only with the held lock inherited on fd 9; a bare claim is refused" {
  # The caller holds the lock on fd 9 and hands it down: not taken twice.
  exec 9>>"$SN2_CONTROL_DIR/moonpool.lock"
  flock 9
  SN2_LOCK_HELD=1 run "$CTL" --json server arm
  envelope; verdict ok verified 0 true
  [ -e "$SN2_CONTROL_DIR/HOST_ARMED" ]
  # Still held here: a plain mutation waits its bounded time and is refused.
  SN2_LOCK_WAIT=1 run "$CTL" --json server disarm
  envelope; verdict refused refused 77 false
  [ "$(field data.protocol_error)" = lock_held ]
  exec 9>&-
  # Another process holds it and this one only claims to: refused, no bypass.
  (flock -x "$SN2_CONTROL_DIR/moonpool.lock" sleep 3) &
  sleep 0.3
  SN2_LOCK_HELD=1 run "$CTL" --json server disarm
  envelope; verdict refused refused 77 false
  [ "$(field data.protocol_error)" = lock_not_held ]
  wait
  [ -e "$SN2_CONTROL_DIR/HOST_ARMED" ]
}

@test "lock: the container-side steps of a host command (stop-game, start-game) wait for the lock" {
  (flock -x "$SN2_CONTROL_DIR/moonpool.lock" sleep 4) &
  sleep 0.3
  SN2_LOCK_WAIT=1 run env SN2_RUN_DIR="$BATS_TEST_TMPDIR/run" "$CTL" --json stop-game
  envelope; verdict refused refused 77 false
  [ ! -e "$BATS_TEST_TMPDIR/run/stopped" ]
  # a read never waits
  SN2_LOCK_WAIT=1 run "$CTL" --json server saves
  envelope; [ "$(field code)" != refused ]
  wait
}

@test "settings apply from the host: one upload under the request id, installed and applied in one locked run" {
  docker_stub
  printf 'weather: clear\nmods: []\n' >"$BATS_TEST_TMPDIR/settings.yaml"
  fake_mod true '{"values":[{"key":"weather","value":"clear","applied":true}],"mods":[]}'
  run env -u SN2_IN_CONTAINER PATH="$stub:$PATH" SN2_SETTINGS_FILE="$BATS_TEST_TMPDIR/settings.yaml" "$CTL" --json settings apply
  wait
  envelope; verdict accepted submitted 0 true
  rid=$(field request_id)
  grep -q "compose cp $BATS_TEST_TMPDIR/settings.yaml sn2:/tmp/sn2-settings-$rid.yaml" "$BATS_TEST_TMPDIR/docker.calls"
  grep -q "sn2 moonpool --json settings apply --from /tmp/sn2-settings-$rid.yaml" "$BATS_TEST_TMPDIR/docker.calls"
  [ "$(cat "$SN2_CONTROL_DIR/settings.yaml")" = "$(printf 'weather: clear\nmods: []')" ]
  [ "$(stat -c %a "$SN2_CONTROL_DIR/settings.yaml")" = 600 ]
  [ ! -e "/tmp/sn2-settings-$rid.yaml" ]
  grep -q '"cmd":"settings"' "$(req)"
}

@test "server restore from the host: a stray argument or a bad save name is 64 before any upload" {
  docker_stub
  : >"$BATS_TEST_TMPDIR/b.tar.gz"
  run env -u SN2_IN_CONTAINER PATH="$stub:$PATH" "$CTL" --json server restore "$BATS_TEST_TMPDIR/b.tar.gz" Slot1 extra
  envelope; verdict invalid_argument refused 64 false
  run env -u SN2_IN_CONTAINER PATH="$stub:$PATH" "$CTL" --json server restore "$BATS_TEST_TMPDIR/b.tar.gz" "../x"
  envelope; verdict invalid_argument refused 64 false
  # nothing reached docker at all: the refusal came before the upload
  [ ! -e "$BATS_TEST_TMPDIR/docker.calls" ]
}

@test "arity: a mutating verb with a stray argument is 64 before any side effect" {
  players_status
  printf 'weather: DA_StormA\n' >"$SN2_CONTROL_DIR/settings.yaml"
  run "$CTL" --json world time 08:00 extra
  envelope; verdict invalid_argument refused 64 false
  [ "$(cat "$SN2_CONTROL_DIR/settings.yaml")" = "weather: DA_StormA" ]
  run "$CTL" --json server arm now
  envelope; verdict invalid_argument refused 64 false
  [ ! -e "$SN2_CONTROL_DIR/HOST_ARMED" ]
  run "$CTL" --json players extra
  envelope; verdict invalid_argument refused 64 false
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
}

# ---- the error map: a stable mod error, the code, and the exact next action ----
golden() { # ERROR CODE EXIT NEXT_ACTION, through a kick as the host
  fake_mod false "$1"
  run "$CTL" --json players kick Someone
  wait
  envelope
  [ "$status" -eq "$3" ]
  [ "$(field code)" = "$2" ]
  [ "$(field data.protocol_error)" = "$1" ]
  [ "$(field next_action)" = "$4" ]
}

@test "error map: unknown player says refresh the player list" {
  golden unknown_player refused 77 "Refresh the player list with: moonpool players, and use a name from it."
  [[ $(field message) == *"no connected player has that name"* ]]
}

@test "error map: a missing host controller says wait for a hosted session" {
  golden host_controller_not_found refused 77 "Wait until moonpool status shows a hosted session, then retry."
}

@test "error map: players online says ask them to leave or use --force" {
  golden players_online refused 77 "Ask the players to leave, or run again with --force (owner only)."
}

@test "error map: a command disabled in the mod's config says enable it; a body-less player says wait" {
  golden disabled_by_config refused 77 "Add the command to enabled_commands in sn2headless.json, recreate the host and retry."
  golden player_has_no_body refused 77 "Wait until the player has a body in the world (a position in status.json), then retry."
}

@test "error map: an error with no entry is still refused, with the code as the reason and no next action" {
  golden something_new refused 77 null
  [[ $(field message) == *"refused by the mod: something_new"* ]]
}

@test "error map: the mod's own protocol checks are protocol_error/70, not a refusal" {
  fake_mod false bad_nonce
  run "$CTL" --json players
  wait
  envelope; verdict protocol_error failed 70 false
  [ "$(field data.protocol_error)" = bad_nonce ]
}

@test "error map: a timeout names the logs and warns against a blind resubmit" {
  SN2_TIMEOUT=1 run "$CTL" --json players kick Someone
  envelope; verdict timeout failed 75 false
  [ "$(field next_action)" = "Inspect the logs (moonpool logs game, moonpool status) before sending again; do not resubmit a mutating command blindly." ]
}

settings_answer() { # every row the mod reports, as its status block
  printf 'weather: %s\nmods: []\n' "$1" >"$SN2_CONTROL_DIR/settings.yaml"
  fake_mod true "$2"
  run "$CTL" --json settings apply
  wait
  envelope
}

@test "error map: settings apply with a refused weather beside an applied key is partial_refusal/78 and names the loaded list" {
  settings_answer foo '{"values":[{"key":"time_of_day","value":"08:00","applied":true},{"key":"weather","value":"foo","applied":false,"reason":"value out of range"}],"mods":[]}'
  verdict partial_refusal partial 78 false
  [ "$(field next_action)" = "Choose a weather type from the loaded list: weather_types in status.json." ]
  [[ $(field message) == *"refused: weather (value out of range)"* ]]
  [ "$(field 'data.values[0].applied')" = true ]
}

@test "error map: settings apply with every key refused is refused/77; with every call run it is accepted" {
  settings_answer foo '{"values":[{"key":"daylight","value":"dim","applied":false,"reason":"value out of range"}],"mods":[]}'
  verdict refused refused 77 false
  [ "$(field next_action)" = "Fix the refused key in settings.yaml (the row names the reason) and apply again." ]
  settings_answer clear '{"values":[{"key":"weather","value":"clear","applied":true}],"mods":[]}'
  verdict accepted submitted 0 true
  [[ $(field message) == *"not read back"* ]]
}

# ---- the command surface: nouns and their verbs -------------------------------
req() { echo "$SN2_CONTROL_DIR/receipts/request.json"; }
players_status() { # a status.json with two players (one with a body) and the loaded weather types
  cat >"$SN2_CONTROL_DIR/status.json" <<'EOF'
{"players":[{"name":"SN2 Host","x":1,"y":2,"z":3},{"name":"Ada","x":-337193,"y":433406,"z":-120,"health":44,"food":20,"water":30,"oxygen":0},{"name":"Bob"}],
 "time_of_day":"08:15","day_fraction":0.34,"clock_frozen":false,"weather":"DA_Clear",
 "weather_types":["DA_Clear","DA_CloudyA","DA_StormA"]}
EOF
}

@test "verbs: players kick and diag console build requests" {
  fake_mod; run "$CTL" players kick Bob; wait; [ "$status" -eq 0 ]
  grep -q '"cmd":"kick","args":{"player":"Bob"}' "$(req)"
  fake_mod; run "$CTL" --json diag console Ada Oxygen 30; wait
  envelope; [ "$(field command)" = diag.console ]
  grep -q '"player":"Ada","command":"Oxygen 30"' "$(req)"
}

@test "map bounds turn two spots on a picture into its edges, and two spots in a line are refused" {
  run "$CTL" --json map bounds 1000 500 100 100 1000 2000 600 400 6000 -1000
  envelope; verdict ok verified 0 true
  [ "$(jq -c .data.bounds <<<"$output")" = '[0,3000,10000,-2000]' ]
  run "$CTL" map bounds 1000 500 100 100 1000 2000 100 400 6000 -1000
  [ "$status" -ne 0 ]
  run "$CTL" map bounds 1000 500 1 100 1000 2000 1.0 400 6000 -1000
  [ "$status" -ne 0 ]
  [[ $output == *"must differ"* ]]
  run "$CTL" map bounds 0 500 100 100 1000 2000 600 400 6000 -1000
  [ "$status" -ne 0 ]
  run "$CTL" map bounds 1000 500 1 2 3
  [ "$status" -ne 0 ]
}

@test "verbs: a missing player is invalid_argument/64 with the connected players under data.options, the host left out" {
  players_status
  run "$CTL" --json players kick
  envelope; verdict invalid_argument refused 64 false
  [ "$(field data.argument)" = player ]
  [ "$(jq -c .data.options <<<"$output")" = '["Ada","Bob"]' ]
  [[ $(field message) == *"choose one of: Ada, Bob"* ]]
  rm "$SN2_CONTROL_DIR/status.json"
  run "$CTL" --json diag console
  envelope; verdict invalid_argument refused 64 false
  [ "$(jq -c .data.options <<<"$output")" = '[]' ]
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
}

@test "verbs: unlocks [player] queues the replay; players invite lists the ID" {
  fake_mod; run "$CTL" unlocks; wait; [ "$status" -eq 0 ]
  grep -q '"cmd":"unlocks","args":{}' "$(req)"
  fake_mod; run "$CTL" unlocks "Example Diver"; wait; [ "$status" -eq 0 ]
  grep -q '"cmd":"unlocks","args":{"player":"Example Diver"}' "$(req)"
  run "$CTL" --json players invite 76561198000000000
  envelope; verdict ok verified 0 true; [ "$(field command)" = players.invite ]
  [ "$(field data.steamid)" = 76561198000000000 ]
  grep -Fxq 76561198000000000 "$SN2_CONTROL_DIR/allowlist.txt"
  run "$CTL" --json players frobnicate
  envelope; verdict invalid_argument refused 64 false; [ "$(field command)" = players ]
}

@test "verbs: server slots, arm, host, saves, save and backup" {
  save_env
  fake_mod; run "$CTL" server slots 08; wait; [ "$status" -eq 0 ]
  grep -q '"cmd":"slots","args":{"slots":8}' "$(req)"
  run "$CTL" --json server arm
  envelope; verdict ok verified 0 true; [ -f "$SN2_CONTROL_DIR/HOST_ARMED" ]
  run "$CTL" --json server host Slot2
  envelope; verdict accepted submitted 0 true; [ "$(field command)" = server.host ]
  [ "$(cat "$SN2_CONTROL_DIR/SAVE_SELECT")" = Slot2 ]
  run "$CTL" --json server host --force
  envelope; verdict invalid_argument refused 64 false
  [ "$(cat "$SN2_CONTROL_DIR/SAVE_SELECT")" = Slot2 ]
  fake_mod true '{"forced":true,"queued":true}'
  run "$CTL" --json server save; wait
  envelope; verdict accepted submitted 0 true
  [ "$(field data.forced)" = true ]
  export SN2_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  printf '#!/bin/sh\nmkdir -p "%s/20260101T000000Z"\n' "$SN2_STAGING_DIR" >"$SN2_BIN/save-stage.sh"
  chmod +x "$SN2_BIN/save-stage.sh"
  run "$CTL" --json server backup
  envelope; verdict ok verified 0 true
  [ "$(field data.staged)" = 20260101T000000Z ]
  printf '#!/bin/sh\necho "FAILED: disk full"; exit 1\n' >"$SN2_BIN/save-stage.sh"
  run "$CTL" --json server backup
  envelope; verdict refused refused 77 false
  run "$CTL" --json server frobnicate
  envelope; verdict invalid_argument refused 64 false
}

@test "verbs: world reads status.json; without one it is unavailable/69" {
  run "$CTL" --json world
  envelope; verdict unavailable failed 69 false
  players_status
  run "$CTL" --json world
  envelope; verdict ok verified 0 true
  [ "$(field data.time_of_day)" = 08:15 ]
  [ "$(field data.weather)" = DA_Clear ]
  [ "$(jq -c .data.weather_types <<<"$output")" = '["DA_Clear","DA_CloudyA","DA_StormA"]' ]
  run "$CTL" world
  [ "$status" -eq 0 ]
  [[ $output == *"weather: DA_Clear"* ]]
  [[ $output == *"loaded weather types: DA_Clear, DA_CloudyA, DA_StormA"* ]]
}

@test "verbs: world weather and time rewrite one key in the control folder's settings.yaml, keep the rest, and apply" {
  players_status
  printf '# kept\ntime_of_day: "03:00"\nweather: DA_StormA\nmods:\n  - name: Example\n    url: https://example.org/m\n' >"$SN2_CONTROL_DIR/settings.yaml"
  fake_mod true '{"values":[{"key":"time_of_day","value":"03:00","applied":true},{"key":"weather","value":"clear","applied":true}],"mods":[]}'
  run "$CTL" --json world weather clear
  wait
  envelope; verdict accepted submitted 0 true
  [ "$(field command)" = world.weather ]
  grep -q '"cmd":"settings"' "$(req)"
  [ "$(cat "$SN2_CONTROL_DIR/settings.yaml")" = "$(printf '# kept\ntime_of_day: "03:00"\nweather: clear\nmods:\n  - name: Example\n    url: https://example.org/m')" ]
  [ "$(stat -c %a "$SN2_CONTROL_DIR/settings.yaml")" = 600 ]
  fake_mod true '{"values":[{"key":"time_of_day","value":"08:00","applied":true},{"key":"weather","value":"clear","applied":true}],"mods":[]}'
  run "$CTL" --json world time 08:00
  wait
  envelope; verdict accepted submitted 0 true
  grep -q '^time_of_day: "08:00"$' "$SN2_CONTROL_DIR/settings.yaml"
  fake_mod true '{"values":[{"key":"daylight","value":"frozen","applied":true}],"mods":[]}'
  run "$CTL" --json world time frozen
  wait
  envelope; verdict accepted submitted 0 true
  grep -q '^daylight: frozen$' "$SN2_CONTROL_DIR/settings.yaml"
  [ "$(grep -c '^time_of_day:' "$SN2_CONTROL_DIR/settings.yaml")" -eq 1 ]
}

@test "verbs: world weather with no settings.yaml creates one; the mod's refusal of that key is refused/77" {
  players_status
  fake_mod true '{"values":[{"key":"weather","value":"DA_StormA","applied":false,"reason":"value out of range"}],"mods":[]}'
  run "$CTL" --json world weather DA_StormA
  wait
  envelope; verdict refused refused 77 false
  [ "$(cat "$SN2_CONTROL_DIR/settings.yaml")" = "weather: DA_StormA" ]
  [ "$(field next_action)" = "Choose a weather type from the loaded list: weather_types in status.json." ]
}

@test "verbs: world weather refuses a type the host has not loaded, and world time a bad value, each with the choices" {
  players_status
  run "$CTL" --json world weather Fog
  envelope; verdict invalid_argument refused 64 false
  [ "$(field data.argument)" = weather ]
  [ "$(jq -c .data.options <<<"$output")" = '["DA_Clear","DA_CloudyA","DA_StormA"]' ]
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
  run "$CTL" world weather
  [ "$status" -eq 64 ]
  [[ $output == *"choose one of: DA_Clear, DA_CloudyA, DA_StormA"* ]]
  run "$CTL" --json world time 25:00
  envelope; verdict invalid_argument refused 64 false
  [ "$(jq -c .data.options <<<"$output")" = '["HH:MM","frozen","normal"]' ]
  run "$CTL" --json world frobnicate
  envelope; verdict invalid_argument refused 64 false
}

@test "verbs: an unknown diag is refused, and so is the removed diag receipt" {
  run "$CTL" --json diag receipt
  envelope; verdict invalid_argument refused 64 false
  run "$CTL" --json diag frobnicate
  envelope; verdict invalid_argument refused 64 false; [ "$(field command)" = diag ]
}

@test "the older one-word spellings are gone: each is an unknown command, and nothing is queued" {
  for old in kick slots host player saves; do
    run "$CTL" --json "$old" Bob
    envelope; verdict invalid_argument refused 64 false
  done
  [ -z "$(ls -A "$SN2_CONTROL_DIR/inbox")" ]
}

@test "the host copy forwards the words as typed" {
  docker_stub
  fake_mod
  run env -u SN2_IN_CONTAINER PATH="$stub:$PATH" "$CTL" players kick Bob
  wait
  [ "$status" -eq 0 ]
  grep -q "sn2 moonpool players kick Bob" "$BATS_TEST_TMPDIR/docker.calls"
}

# --- Container start (scripts/common.sh container_start) --------------------
# The kernel's own record of PID 1's start, never the mtime of /proc/1: procfs re-stamps
# that inode after a cache drop, and the Steam sign-in check then rejected a
# real logon as older than the container.

container_start_with() {
  bash -c "SN2_PROC_STAT='$1' SN2_PROC_PID1_STAT='$2' bash -c \". '$BATS_TEST_DIRNAME/../scripts/common.sh'; container_start\""
}

@test "container start: boot time plus PID 1's start ticks, past a command name with ') ' in it" {
  printf 'cpu  1 2 3\nbtime 1793660000\nprocesses 5\n' >"$BATS_TEST_TMPDIR/stat"
  printf '1 (my init) proc) S 0 1 1 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 1234500 3000000 200\n' \
    >"$BATS_TEST_TMPDIR/pid1"
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  run container_start_with "$BATS_TEST_TMPDIR/stat" "$BATS_TEST_TMPDIR/pid1"
  [ "$status" -eq 0 ]
  [ "$output" = "$((1793660000 + 1234500 / hz))" ]
}

@test "container start: unreadable kernel files fall back to a number, never empty" {
  run container_start_with /nonexistent/stat /nonexistent/pid1
  [ "$status" -eq 0 ]
  [[ $output =~ ^[0-9]+$ ]]
}

@test "Lua notify sends through the game's static path, falls back, and targets named joiners" {
  run lua5.4 tests/lua/notify_spec.lua
  [ "$status" -eq 0 ]
  [[ $output == *"all passed"* ]]
}

@test "every Lua spec is run by a bats test" {
  specs=0 unrun=""
  for spec in tests/lua/*_spec.lua; do
    specs=$((specs + 1))
    grep -q "tests/lua/$(basename "$spec")" tests/*.bats || unrun="$unrun $(basename "$spec")"
  done
  # A floor, so a moved or renamed spec folder cannot pass by reading nothing.
  [ "$specs" -ge 15 ]
  [ -z "$unrun" ] || { echo "specs no bats test runs:$unrun"; false; }
}

@test "Lua status keeps player paths, never objects, so a freed player is never read" {
  run lua5.4 tests/lua/status_spec.lua
  [ "$status" -eq 0 ]
  [[ $output == *"status_spec: ok"* ]]
}

@test "install-ue4ss tries this repository's mirror of the pinned loader before upstream" {
  f="$BATS_TEST_DIRNAME/../scripts/install-ue4ss.sh"
  mirror=$(grep -n "fetch_pinned \"\${UE4SS_MIRROR:-" "$f" | cut -d: -f1)
  upstream=$(grep -n "fetch_pinned \"\$UE4SS_URL\"" "$f" | cut -d: -f1)
  [ -n "$mirror" ] && [ -n "$upstream" ] && [ "$mirror" -lt "$upstream" ]
  grep -q 'releases/download/ue4ss-mirror' "$f"
}
