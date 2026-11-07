#!/usr/bin/env bash
# Copies the game log's join and slot lines to $LOG_DIR/join_watch.log, writes metrics and a
# heartbeat, and refreshes the Discord card.
set -u
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

# The game's own log: the public build's console output carries only warnings.
GAME_LOG="${JOIN_WATCH_LOG:-$UE_LOG}"
OUT="$LOG_DIR/join_watch.log"
PAT='PostLogin|Login request|Join succeeded|Join request|NotifyAcceptingConnection|NotifyAcceptedConnection|AddClientConnection|UNetConnection|NetConnection.*(Open|Close|Cleanup)|registered players|NumOpenPrivateConnections|NumPrivateConnections|RegisterPlayer|UnregisterPlayer|OnSessionParticipant|OnCreateSessionComplete|LobbyId=Lobby\[0x|SessionId: Lobby\[0x|LobbyMemberStatus|member (joined|left)|PeerConnectionEstablished|Connection established|NetworkType=|ConnectionType=|IncomingConnection|connection request|Logout|PlayerState|HandleStartingNewPlayer|Kicked|rejected|Server full|MaxPlayers|autosave_completed'

mkdir -p "$LOG_DIR"
stamp() { date -u +%FT%TZ; }
echo "[$(stamp)] join watch started; following $GAME_LOG" >>"$OUT"

NOTIFY="$(dirname "$0")/discord-notify.py"
METRICS="$DATA_DIR/metrics.csv"
[ -f "$METRICS" ] || echo "utc,cpu_cores,mem_mib,players" >"$METRICS"
# The whole container: the game is many Wine processes, and its pid is only the shell waiting on them.
usage_usec_was=''; usage_at_was=''
container_usage() {
  local dir=${SN2_CGROUP:-/sys/fs/cgroup} usec at total inactive
  cpu=0; mem=0
  usec=$(awk '$1 == "usage_usec" {print $2}' "$dir/cpu.stat" 2>/dev/null) || usec=''
  total=$(cat "$dir/memory.current" 2>/dev/null) || total=''
  inactive=$(awk '$1 == "inactive_file" {print $2}' "$dir/memory.stat" 2>/dev/null) || inactive=''
  at=$(date +%s)
  [ -z "$total" ] || mem=$(( (total - ${inactive:-0}) / 1048576 ))
  if [ -n "$usec" ] && [ -n "$usage_usec_was" ] && [ "$at" -gt "$usage_at_was" ]; then
    cpu=$(awk -v a="$usec" -v b="$usage_usec_was" -v s="$((at - usage_at_was))" 'BEGIN {printf "%.2f", (a - b) / 1000000 / s}')
  fi
  usage_usec_was=$usec; usage_at_was=$at
}
names() { jq -r --arg h "$HOST_NAME" '.players[]? | select(.name != $h) | .name' "$CONTROL_DIR/status.json" 2>/dev/null | sort; }
record_lobby() { # hex lobby id from the UE log
  local lobby=$1 sid
  sid=$(host_steamid)
  [ -n "$sid" ] || return 0
  jq -cn --arg lobby "$lobby" --arg sid "$sid" '{lobby_id:$lobby,host_steamid:$sid}' \
    >"$RUN_DIR/mod-session.json.tmp"
  mv "$RUN_DIR/mod-session.json.tmp" "$RUN_DIR/mod-session.json"
  python3 "$(dirname "$0")/join-page.py" || true
}

# A watcher restart recovers the hosted lobby from the log; the public build masks its id.
LOBBY_RE='(LobbyId=|SessionId: )Lobby\[(0x[0-9A-Fa-f]+)\]'
# The log outlives the game: only a running game means its last lobby is still open.
if [ -n "$(game_pid)" ]; then
  last_lobby=$(grep -aoE "$LOBBY_RE" "$GAME_LOG" 2>/dev/null | tail -n1 | sed -E 's/.*\[(0x[0-9A-Fa-f]+)\]/\1/' || true)
  [ -z "$last_lobby" ] || record_lobby "$last_lobby"
else
  rm -f "$RUN_DIR/mod-session.json"
fi

# Every 30 s: stage a save, read players, follow up/stopped, backups and updates.
# Every minute: metrics, status card, viewer line. Every 5 minutes: a heartbeat.
heartbeat() {
  local s n=0 was='' now cur pid cpu mem cnt build oldbuild title lobby known restart_warning_pid='' restart_rc
  oldbuild=$(cat "$RUN_DIR/last-buildid" 2>/dev/null)
  python3 "$NOTIFY" status >/dev/null 2>&1 || true
  while sleep 30; do
    "$(dirname "$0")/save-stage.sh" || true # stages a save once it is quiet
    n=$((n + 1)); pid=$(game_pid)
    if [ -n "$pid" ]; then now=up; else now=down; fi
    if [ "$now" != "$was" ] && [ -n "$was" ]; then
      # down after a new crash report folder (the engine's Saved/Crashes) is a crash.
      if [ "$now" = up ]; then python3 "$NOTIFY" event up; : >"$RUN_DIR/up-since"
      elif [ "$(cat "$DATA_DIR/discord/override" 2>/dev/null)" = updating ] || [ -f "$STOP_FLAG" ]; then
        python3 "$NOTIFY" status
      elif [ -n "$(find "$GAME_DIR/Subnautica2/Saved/Crashes" -mindepth 1 -maxdepth 1 -newer "$RUN_DIR/up-since" 2>/dev/null | head -1)" ]; then
        python3 "$NOTIFY" event outage "the game stopped unexpectedly"
      else python3 "$NOTIFY" event outage "the server stopped unexpectedly"; fi
    fi
    if [ "$now" = down ] && [ -f "$RUN_DIR/mod-session.json" ]; then
      rm -f "$RUN_DIR/mod-session.json"
      python3 "$(dirname "$0")/join-page.py" || true
    fi
    was=$now
    # Only a countdown that completed stops the game.
    if [ -n "$restart_warning_pid" ] && ! kill -0 "$restart_warning_pid" 2>/dev/null; then
      if wait "$restart_warning_pid"; then
        pid=$(game_pid)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        echo "[$(stamp)] in-game admin: countdown and save completed; game process stopped for supervisor restart" >>"$OUT"
      else
        restart_rc=$?
        echo "[$(stamp)] in-game admin: countdown ended without restart (status $restart_rc)" >>"$OUT"
      fi
      restart_warning_pid=''
    fi
    # IDLE_STOP_HOURS: the mod asks and the game stops; `moonpool server start` or RESTART_CRON clears it.
    if [ -f "$CONTROL_DIR/idle-stop-request.json" ]; then
      rm -f "$CONTROL_DIR/idle-stop-request.json"
      if CONTROL_DIR="$CONTROL_DIR" session_up; then
        echo "[$(stamp)] idle: stop request dropped because someone is online now" >>"$OUT"
      else
        : >"$STOP_FLAG"; : >"$RUN_DIR/idle-stopped"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        echo "[$(stamp)] idle: nobody in for ${IDLE_STOP_HOURS:-?} h; game stopped (moonpool server start brings it back)" >>"$OUT"
      fi
    fi
    # An in-game admin restart stops the game and the supervisor starts it again.
    if [ -f "$CONTROL_DIR/admin-restart-request.json" ]; then
      rm -f "$CONTROL_DIR/admin-restart-request.json"
      if [ -z "$restart_warning_pid" ]; then
        "$(dirname "$0")/restart-warning.sh" run "restart asked for in game" >>"$OUT" 2>&1 &
        restart_warning_pid=$!
        echo "[$(stamp)] in-game admin: restart countdown started in background" >>"$OUT"
      fi
    fi
    if [ -f "$CONTROL_DIR/admin-restart-cancel.json" ]; then
      rm -f "$CONTROL_DIR/admin-restart-cancel.json"
      "$(dirname "$0")/restart-warning.sh" cancel >>"$OUT" 2>&1
    fi
    cur=$(names)
    # Never on the watcher's first read: a restart would greet everyone already in.
    if [ -n "${prev_names+x}" ]; then
      while IFS= read -r who; do [ -z "$who" ] || python3 "$NOTIFY" event join "$who"; done < <(grep -Fxv -f <(printf '%s\n' "$prev_names") <<<"$cur")
      while IFS= read -r who; do [ -z "$who" ] || python3 "$NOTIFY" event leave "$who"; done < <(grep -Fxv -f <(printf '%s\n' "$cur") <<<"$prev_names")
      prev_names=$(greet_joiners "$prev_names" "$cur" 2>>"$OUT")
    else
      prev_names=$cur
    fi
    if grep -q FAILED "$BACKUP_STATUS" 2>/dev/null && [ ! -f "$RUN_DIR/backup-failed-sent" ]; then
      : >"$RUN_DIR/backup-failed-sent"
    elif ! grep -q FAILED "$BACKUP_STATUS" 2>/dev/null; then rm -f "$RUN_DIR/backup-failed-sent"; fi
    build=$("$(dirname "$0")/steam-config.sh" --report 2>/dev/null | sed -nE 's/.*buildid=([0-9]+).*/\1/p')
    if [ -n "$build" ] && [ "$build" != "$oldbuild" ]; then
      [ -n "$oldbuild" ] && python3 "$NOTIFY" event update "build $oldbuild -> $build"
      echo "$build" >"$RUN_DIR/last-buildid"; oldbuild=$build
    fi
    [ $((n % 2)) -eq 0 ] || continue
    # Every minute: accept pending friend requests from invited players (AUTO_ACCEPT_FRIENDS=1).
    if [ "${AUTO_ACCEPT_FRIENDS:-1}" = 1 ]; then
      STEAM_HTMLCACHE="$STEAM_SESSION_DIR/htmlcache" python3 "$(dirname "$0")/friend-accept.py" 2>&1 |
        grep -v '^friend accept skipped' | sed "s/^/[$(stamp)] /" >>"$OUT" || true
    fi
    # For a build whose log masks the lobby id, Steam's own answer: once, then every 5 minutes.
    if [ -n "$pid" ] && jq -e '.hosted == true' "$CONTROL_DIR/readiness.json" >/dev/null 2>&1 &&
      { [ ! -s "$RUN_DIR/mod-session.json" ] || [ $((n % 10)) -eq 0 ]; }; then
      lobby=$(STEAM_HTMLCACHE="$STEAM_SESSION_DIR/htmlcache" python3 "$(dirname "$0")/friend-accept.py" \
        --lobby "$(host_steamid)" 2>/dev/null || true)
      known=$(jq -r '.lobby_id // empty' "$RUN_DIR/mod-session.json" 2>/dev/null)
      [ -z "$known" ] || known=$(printf '%d' "$known" 2>/dev/null || echo "$known")
      case $lobby in
        '' | *[!0-9]*) ;;
        "$known") ;;
        *) echo "[$(stamp)] lobby $lobby (from Steam: the game log does not carry it whole)" >>"$OUT"; record_lobby "$lobby" ;;
      esac
    fi
    cnt=$(printf '%s' "$cur" | grep -c . || true)
    container_usage
    echo "$(stamp),$cpu,$mem,$cnt" >>"$METRICS"
    CONTROL_DIR="$CONTROL_DIR" MAP_PUBLIC_URL="$(public_url)" python3 "$(dirname "$0")/map-chart.py" >>"$OUT" 2>&1 || true
    python3 "$NOTIFY" status >/dev/null 2>&1 || true
    title="SN2 host - $now - $cnt/$PLAYER_SLOTS online: $(printf '%s' "$cur" | paste -sd, -)"
    grep -q FAILED "$BACKUP_STATUS" 2>/dev/null && title="$title - BACKUP FAILED"
    x11vnc -display "$DISPLAY" -R "desktop:${title:0:100}" >/dev/null 2>&1 || true
    [ $((n % 10)) -eq 0 ] || continue
    if [ -n "$pid" ]; then s=alive; else s="NOT RUNNING"; fi
    echo "[$(stamp)] heartbeat: game $s" >>"$OUT" # the heartbeat posts nothing to Discord
  done
}
python3 "$(dirname "$0")/join-page.py" || true
heartbeat &
trap 'kill $! 2>/dev/null' EXIT

tail -n 0 -F "$GAME_LOG" 2>/dev/null | grep -a --line-buffered -E "$PAT" |
  while IFS= read -r line; do
    echo "[$(stamp)] ${line%$'\r'}" >>"$OUT"
    line_shows_player_join "$line" && : >"$RUN_DIR/player-joined"
    # An autosave just finished: stage a copy for offen to archive.
    case $line in *autosave_completed*) "$(dirname "$0")/save-stage.sh" --now || true ;; esac
    if [[ $line =~ $LOBBY_RE ]]; then
      record_lobby "${BASH_REMATCH[2]}"
    fi
  done
