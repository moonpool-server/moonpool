#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2016
setup() {
  export DATA_DIR="$BATS_TEST_TMPDIR/data" SN2_CONTROL_DIR="$BATS_TEST_TMPDIR/data/control"
  export UE_LOG="$BATS_TEST_TMPDIR/data/game.log"
  export RESTART_WARNING_SECONDS=1 RESTART_SAVE_WAIT_SECONDS=0 HOST_NAME='SN2 Host'
  mkdir -p "$SN2_CONTROL_DIR" "$DATA_DIR/run"
  printf '{"hosted":true}' >"$SN2_CONTROL_DIR/readiness.json"
  printf '{"players":[{"name":"SN2 Host"},{"name":"Diver"}]}' >"$SN2_CONTROL_DIR/status.json"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/discord-notify.sh"
  chmod +x "$BATS_TEST_TMPDIR/bin/discord-notify.sh"
  cp scripts/restart-warning.sh scripts/common.sh "$BATS_TEST_TMPDIR/bin/"
}
@test "online player gets countdown and empty server does not wait" {
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run test
  [ "$status" -eq 0 ]; [ -f "$SN2_CONTROL_DIR/notify-request.json" ]
  printf '{"players":[{"name":"SN2 Host"}]}' >"$SN2_CONTROL_DIR/status.json"
  rm -f "$SN2_CONTROL_DIR/notify-request.json" "$DATA_DIR/run/restart-warning.done"
  start=$(date +%s%N)
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run test
  elapsed_ms=$(( ( $(date +%s%N) - start ) / 1000000 ))
  [ "$status" -eq 0 ]; [ ! -f "$SN2_CONTROL_DIR/notify-request.json" ]
  [ "$elapsed_ms" -lt 500 ]
}

@test "a join observed after the last empty status makes the countdown warn" {
  printf '{"players":[{"name":"SN2 Host"}]}' >"$SN2_CONTROL_DIR/status.json"
  sleep .1
  : >"$DATA_DIR/run/player-joined"
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run test
  [ "$status" -eq 0 ]
  [ -f "$SN2_CONTROL_DIR/notify-request.json" ]
}

@test "running game with unreadable or stale status warns conservatively" {
  export GAME_EXE_NAME=sleep
  /bin/sleep 10 & game_pid=$!
  printf 'not json' >"$SN2_CONTROL_DIR/status.json"
  run env RESTART_WARNING_SECONDS=0 "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run unreadable
  [ "$status" -eq 0 ]; [ -f "$SN2_CONTROL_DIR/notify-request.json" ]
  rm -f "$SN2_CONTROL_DIR/notify-request.json" "$DATA_DIR/run/restart-warning.done"
  printf '{"players":[{"name":"SN2 Host"}]}' >"$SN2_CONTROL_DIR/status.json"
  touch -t 200001010000 "$SN2_CONTROL_DIR/status.json"
  run env RESTART_WARNING_SECONDS=0 "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run stale
  [ "$status" -eq 0 ]; [ -f "$SN2_CONTROL_DIR/notify-request.json" ]
  kill "$game_pid" 2>/dev/null || true
}
@test "cancel interrupts one countdown" {
  RESTART_WARNING_SECONDS=3 "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run test & pid=$!
  for _ in $(seq 1 20); do [ -f "$DATA_DIR/run/restart-warning.json" ] && break; sleep .1; done
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" cancel
  [ "$status" -eq 0 ]; wait "$pid" || [ "$?" -eq 125 ]
  [ "$(jq -r .kind "$SN2_CONTROL_DIR/notify-request.json")" = cancel ]
}
@test "a second countdown reports time left instead of stacking" {
  RESTART_WARNING_SECONDS=3 "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run first & pid=$!
  for _ in $(seq 1 20); do [ -f "$DATA_DIR/run/restart-warning.json" ] && break; sleep .1; done
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run second
  [ "$status" -eq 75 ]; [[ "$output" == *"already running"*"left"* ]]
  "$BATS_TEST_TMPDIR/bin/restart-warning.sh" cancel >/dev/null
  wait "$pid" || [ "$?" -eq 125 ]
}
@test "countdown forces a save at ten seconds and reports completed save before final toast" {
  export RESTART_WARNING_SECONDS=10 RESTART_SAVE_WAIT_SECONDS=2
  export MOONPOOL="$BATS_TEST_TMPDIR/bin/moonpool"
  cat >"$MOONPOOL" <<'SH'
#!/bin/sh
echo "$*" >>"$DATA_DIR/moonpool.calls"
( sleep .2; echo autosave_completed >>"$UE_LOG" ) &
printf '{"verdict":"accepted"}\n'
SH
  chmod +x "$MOONPOOL"
  mkdir -p "$(dirname "$UE_LOG")"; : >"$UE_LOG"
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run test
  [ "$status" -eq 0 ]
  grep -q -- '--json server save' "$DATA_DIR/moonpool.calls"
  [ "$(jq -r .save_completed "$DATA_DIR/run/restart-warning-receipt.json")" = true ]
  [ "$(jq -r .header "$SN2_CONTROL_DIR/notify-request.json")" = "Restarting now" ]
  [ "$(jq -r .text "$SN2_CONTROL_DIR/notify-request.json")" = "The world is saved. Rejoin in a minute or two." ]
}

@test "internal countdown shares its parent lock and the save reaches the mod inbox" {
  export RESTART_WARNING_SECONDS=0 RESTART_SAVE_WAIT_SECONDS=0 SN2_IN_CONTAINER=1 SN2_TIMEOUT=2
  export SN2_BIN="$BATS_TEST_TMPDIR/bin" SN2_RUN_DIR="$DATA_DIR/run"
  export SN2_COMMON="$BATS_TEST_TMPDIR/bin/common.sh"
  export MOONPOOL="$BATS_TEST_TMPDIR/bin/moonpool"
  cp bin/moonpool "$MOONPOOL"; chmod +x "$MOONPOOL"
  mkdir -p "$SN2_CONTROL_DIR"/{inbox,outbox,tmp,receipts}
  chmod 700 "$SN2_CONTROL_DIR"
  : >"$UE_LOG"
  (
    for _ in $(seq 1 40); do
      for request in "$SN2_CONTROL_DIR"/inbox/*.json; do
        [ -f "$request" ] || continue
        cp "$request" "$DATA_DIR/save-request.json"
        id=$(jq -r .id "$request")
        jq -cn --arg id "$id" '{v:1,accepts:[1],id:$id,ok:true,cmd:"save",data:{},meta:{game_build_id:"test",mod_version:"test"}}' >"$SN2_CONTROL_DIR/outbox/$id.json"
        exit 0
      done
      sleep .05
    done
    exit 1
  ) & mod_pid=$!
  run "$MOONPOOL" restart-warning test
  [ "$status" -eq 0 ]
  wait "$mod_pid"
  [ "$(jq -r .cmd "$DATA_DIR/save-request.json")" = save ]
}

@test "countdown is honest when forced save completion times out" {
  export RESTART_WARNING_SECONDS=0 RESTART_SAVE_WAIT_SECONDS=1
  export MOONPOOL="$BATS_TEST_TMPDIR/bin/moonpool"
  printf '#!/bin/sh\nprintf '\''{"verdict":"accepted"}\\n'\''\n' >"$MOONPOOL"
  chmod +x "$MOONPOOL"
  mkdir -p "$(dirname "$UE_LOG")"; : >"$UE_LOG"
  # A hosted session with a zero warning still forces and waits for its save.
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run test
  [ "$status" -eq 0 ]
  [ "$(jq -r .save_completed "$DATA_DIR/run/restart-warning-receipt.json")" = false ]
  [ "$(jq -r .text "$SN2_CONTROL_DIR/notify-request.json")" = "Rejoin in a minute or two." ]
}

@test "a save file written after the request counts as a completed save without the log line" {
  export RESTART_WARNING_SECONDS=0 RESTART_SAVE_WAIT_SECONDS=3 SAVE_DIR="$BATS_TEST_TMPDIR/saves"
  export MOONPOOL="$BATS_TEST_TMPDIR/bin/moonpool"
  mkdir -p "$SAVE_DIR"; touch -t 200001010000 "$SAVE_DIR/Slot1.sav"
  cat >"$MOONPOOL" <<'SH'
#!/bin/sh
( sleep 1.2; echo new >"$SAVE_DIR/Slot1.sav" ) &
printf '{"verdict":"accepted"}
'
SH
  chmod +x "$MOONPOOL"
  mkdir -p "$(dirname "$UE_LOG")"; : >"$UE_LOG"
  run "$BATS_TEST_TMPDIR/bin/restart-warning.sh" run test
  # On failure, show what decided it: the script's output, the receipt and the save's mtime.
  echo "output: $output"; cat "$DATA_DIR/run/restart-warning-receipt.json" 2>&1
  stat -c '%n %y' "$SAVE_DIR/Slot1.sav" 2>&1
  [ "$status" -eq 0 ]
  [ "$(jq -r .save_completed "$DATA_DIR/run/restart-warning-receipt.json")" = true ]
}

@test "join watcher stays alive, cancels an active countdown, and drops an unsafe idle stop" {
  cp scripts/join-watch.sh "$BATS_TEST_TMPDIR/bin/"
  for helper in join-page.py save-stage.sh steam-config.sh friend-accept.py; do
    printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/$helper"; chmod +x "$BATS_TEST_TMPDIR/bin/$helper"
  done
  mkdir -p "$DATA_DIR/logs" "$BATS_TEST_TMPDIR/tools"
  : >"$UE_LOG"
  cat >"$BATS_TEST_TMPDIR/tools/sleep" <<'SH'
#!/bin/sh
/bin/sleep .05
SH
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/tools/x11vnc"
  cat >"$BATS_TEST_TMPDIR/tools/grep" <<'SH'
#!/bin/sh
if [ "${1:-}" = -a ] && [ "${2:-}" = --line-buffered ]; then shift 2; set -- -a "$@"; fi
exec /bin/grep "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/tools/"*
  export PATH="$BATS_TEST_TMPDIR/tools:$PATH" JOIN_WATCH_LOG="$UE_LOG" RESTART_WARNING_SECONDS=5
  "$BATS_TEST_TMPDIR/bin/join-watch.sh" & watcher=$!
  for _ in $(seq 1 40); do grep -q 'join watch started' "$DATA_DIR/logs/join_watch.log" 2>/dev/null && break; /bin/sleep .05; done
  /bin/sleep .2
  echo 'PostLogin: Diver' >>"$UE_LOG"
  for _ in $(seq 1 40); do [ -f "$DATA_DIR/run/player-joined" ] && break; /bin/sleep .05; done
  [ -f "$DATA_DIR/run/player-joined" ]
  : >"$SN2_CONTROL_DIR/admin-restart-request.json"
  for _ in $(seq 1 60); do [ -f "$DATA_DIR/run/restart-warning.json" ] && break; /bin/sleep .05; done
  [ -f "$DATA_DIR/run/restart-warning.json" ]
  : >"$SN2_CONTROL_DIR/admin-restart-cancel.json"
  for _ in $(seq 1 60); do
    [ "$(jq -r .kind "$SN2_CONTROL_DIR/notify-request.json" 2>/dev/null)" = cancel ] && break
    /bin/sleep .05
  done
  [ "$(jq -r .kind "$SN2_CONTROL_DIR/notify-request.json")" = cancel ]
  kill -0 "$watcher"
  : >"$SN2_CONTROL_DIR/idle-stop-request.json"
  for _ in $(seq 1 60); do grep -q 'stop request dropped because someone is online now' "$DATA_DIR/logs/join_watch.log" 2>/dev/null && break; /bin/sleep .05; done
  grep -q 'stop request dropped because someone is online now' "$DATA_DIR/logs/join_watch.log"
  [ ! -e "$DATA_DIR/run/stopped" ]
  for _ in $(seq 1 120); do grep -q 'heartbeat: game' "$DATA_DIR/logs/join_watch.log" 2>/dev/null && break; /bin/sleep .05; done
  grep -q 'heartbeat: game' "$DATA_DIR/logs/join_watch.log"
  children=$(pgrep -P "$watcher" 2>/dev/null || true)
  while IFS= read -r child; do [ -z "$child" ] || kill "$child" 2>/dev/null || true; done <<<"$children"
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" || true
}

@test "a second TERM cannot interrupt the warning and save handler" {
  cat >"$BATS_TEST_TMPDIR/bin/warn" <<'SH'
#!/bin/sh
echo started >"$DATA_DIR/warn.state"
sleep 1
echo completed >"$DATA_DIR/warn.state"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/warn"
  export RESTART_WARNING_SCRIPT="$BATS_TEST_TMPDIR/bin/warn" GAME_EXE_NAME=SN2NoSuchProcess
  bash -c '. "$1"; trap term_stop TERM INT; : >"$DATA_DIR/term-ready"; while :; do sleep 1; done' _ "$BATS_TEST_TMPDIR/bin/common.sh" & shell_pid=$!
  for _ in $(seq 1 40); do [ -f "$DATA_DIR/term-ready" ] && break; /bin/sleep .05; done
  kill -TERM "$shell_pid"
  for _ in $(seq 1 40); do [ -f "$DATA_DIR/warn.state" ] && break; /bin/sleep .05; done
  kill -TERM "$shell_pid"
  wait "$shell_pid"
  [ "$(cat "$DATA_DIR/warn.state")" = completed ]
}

@test "panel image carries the complete shutdown budget without Compose" {
  grep -q 'S6_SERVICES_GRACETIME=210000' Dockerfile
  grep -q 'S6_KILL_GRACETIME=5000' Dockerfile
}
