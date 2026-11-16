#!/usr/bin/env bats
# The join watcher must capture the EOS connection-type line, which carries the
# authoritative direct-vs-relay proof (NetworkType=[EOS_NCT_DirectConnection]).
# Before, PAT dropped it, so a direct connection could never be proven from the log.

pat() { sed -n "s/^PAT='\(.*\)'\$/\1/p" "$BATS_TEST_DIRNAME/../scripts/join-watch.sh"; }

@test "PAT captures a direct-connection establishment line" {
  line='[2026.11.04-02.12.18:900][98]LogEOSSDK: LogEOSP2P: Connection established. ConnectionType=[EOS_CET_NewConnection] NetworkType=[EOS_NCT_DirectConnection]'
  run grep -qE "$(pat)" <<<"$line"
  [ "$status" -eq 0 ]
}

@test "PAT captures a relayed-connection establishment line" {
  line='[2026.11.03-17.59.55:900][854]LogEOSSDK: LogEOSP2P: Connection established. NetworkType=[EOS_NCT_RelayedConnection]'
  run grep -qE "$(pat)" <<<"$line"
  [ "$status" -eq 0 ]
}

@test "PAT ignores ordinary gameplay noise" {
  line='[2026.11.04-02.12.24:571][683]LogUWEAnalytics: Warning: RecordPlayerEvent item_equipped'
  run grep -qE "$(pat)" <<<"$line"
  [ "$status" -ne 0 ]
}

# The watcher's heartbeat with its helpers stubbed and its 30 s sleep cut short, run until the stub
# friend-accept.py has been called $1 times. The stub prints the lines of $DATA_DIR/fa.lines, one per call.
run_watcher_until_friend_calls() {
  local b="$BATS_TEST_TMPDIR/bin" t="$BATS_TEST_TMPDIR/tools" watcher children
  export DATA_DIR="$BATS_TEST_TMPDIR/data" SN2_CONTROL_DIR="$BATS_TEST_TMPDIR/data/control" HOST_NAME='SN2 Host'
  export UE_LOG="$DATA_DIR/game.log" JOIN_WATCH_LOG="$DATA_DIR/game.log" PATH="$t:$PATH"
  mkdir -p "$b" "$t" "$SN2_CONTROL_DIR" "$DATA_DIR/run" "$DATA_DIR/logs"; : >"$UE_LOG"
  cp "$BATS_TEST_DIRNAME/../scripts/join-watch.sh" "$BATS_TEST_DIRNAME/../scripts/common.sh" "$b/"
  for helper in join-page.py discord-notify.py map-chart.py; do printf 'import sys\nsys.exit(0)\n' >"$b/$helper"; done
  for helper in save-stage.sh steam-config.sh; do printf '#!/bin/sh\nexit 0\n' >"$b/$helper"; chmod +x "$b/$helper"; done
  cat >"$b/friend-accept.py" <<'PY'
import os, sys
d = os.environ["DATA_DIR"]
counter = os.path.join(d, "fa.n")
n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
lines = open(os.path.join(d, "fa.lines")).read().splitlines()
line = lines[n - 1] if n <= len(lines) else ('{"count": 0, "names": []}' if "--pending" in sys.argv else "")
print(line, flush=True)
open(counter, "w").write(str(n))
sys.exit(1 if line.startswith("friend accept ") else 0)
PY
  printf '#!/bin/sh\n/bin/sleep .05\n' >"$t/sleep"
  printf '#!/bin/sh\nexit 0\n' >"$t/x11vnc"
  cat >"$t/grep" <<'SH'
#!/bin/sh
if [ "${1:-}" = -a ] && [ "${2:-}" = --line-buffered ]; then shift 2; set -- -a "$@"; fi
exec /bin/grep "$@"
SH
  chmod +x "$t/"*
  "$b/join-watch.sh" & watcher=$!
  for _ in $(seq 1 200); do [ "$(cat "$DATA_DIR/fa.n" 2>/dev/null || echo 0)" -ge "$1" ] && break; /bin/sleep .05; done
  /bin/sleep .3
  children=$(pgrep -P "$watcher" 2>/dev/null || true)
  while IFS= read -r child; do [ -z "$child" ] || kill "$child" 2>/dev/null || true; done <<<"$children"
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" || true
}

@test "friend accept: an expected skip stays out of the log; a failure is logged once until it changes" {
  mkdir -p "$BATS_TEST_TMPDIR/data"
  printf '%s\n' 'friend accept skipped: NotReady: no web session yet' 'friend accept failed: HTTPError: HTTP Error 500' \
    'friend accept failed: HTTPError: HTTP Error 500' 'friend accepted: Diver (76561198000000002)' >"$BATS_TEST_TMPDIR/data/fa.lines"
  AUTO_ACCEPT_FRIENDS=1 run_watcher_until_friend_calls 4
  log="$BATS_TEST_TMPDIR/data/logs/join_watch.log"; cat "$log"
  [ "$(grep -c 'friend accept skipped' "$log")" -eq 0 ]
  [ "$(grep -c 'friend accept failed: HTTPError' "$log")" -eq 1 ]
  grep -q 'friend accepted: Diver' "$log"
}

@test "friend accept: a failed read-only count reaches the log" {
  mkdir -p "$BATS_TEST_TMPDIR/data"
  printf '%s\n' 'friend accept failed: ValueError: friends list refused: success=2' >"$BATS_TEST_TMPDIR/data/fa.lines"
  AUTO_ACCEPT_FRIENDS=0 run_watcher_until_friend_calls 1
  log="$BATS_TEST_TMPDIR/data/logs/join_watch.log"; cat "$log"
  grep -q 'friend accept failed: ValueError: friends list refused' "$log"
}
