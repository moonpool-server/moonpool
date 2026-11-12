#!/usr/bin/env bash
# Run the Subnautica 2 client headless under Wine, in the foreground until it exits. The mod
# idles in the front end until $CONTROL_DIR/HOST_ARMED exists, then calls the game's Host code once.
set -u
# shellcheck source=common.sh
. /opt/sn2/bin/common.sh

if [ -n "$(game_pid)" ]; then
  log "game already running (pid $(game_pid))"
  exit 0
fi
if ! steam_running; then
  log "Steam client is not running; the game needs it signed in. Not launching."
  exit 1
fi
if [ ! -f "$WIN64_DIR/$GAME_EXE_NAME" ]; then
  log "game not installed at $WIN64_DIR; see scripts/install-game.sh"
  exit 1
fi

# Started outside the Steam client, the game's Steam API needs steam_appid.txt beside the
# executable, or it exits with "SteamAPI failed to initialize".
if [ "$(cat "$WIN64_DIR/steam_appid.txt" 2>/dev/null)" != "$GAME_APP_ID" ]; then
  printf '%s' "$GAME_APP_ID" >"$WIN64_DIR/steam_appid.txt" &&
    log "wrote steam_appid.txt ($GAME_APP_ID) beside the game executable"
fi

# The mod owns submitted inbox entries, so it can answer them after a crash; only unpublished
# temp files go here, with the last run's readiness.
rm -f "$CONTROL_DIR/readiness.json" "$CONTROL_DIR"/tmp/*.json

overrides=""
if [ "$NATIVE_MSVC" = "1" ]; then
  missing=""
  for d in $MSVC_DLLS; do [ -f "$WIN64_DIR/$d" ] || missing="$missing $d"; done
  if [ -n "$missing" ]; then
    log "native C++ runtime missing in the game folder:$missing; run install-msvc-runtime.sh. Using Wine's."
  else
    overrides="$(echo "$MSVC_DLLS" | sed 's/\.dll//g; s/ /,/g')=n;"
  fi
fi
if [ "$UE4SS_AT_START" = "true" ]; then
  mode=$(ue4ss_launch_mode "$WIN64_DIR")
  case $mode in
    loader)
      overrides="${overrides}dwmapi=n,b"
      log "UE4SS loads at process start through its dwmapi.dll proxy" ;;
    *)
      overrides="${overrides}dwmapi=b"
      mkdir -p "$LOG_DIR"
      log "UE4SS held back, game starts without it; ${mode#held }. Waiting for the loader: $UE4SS_SERVES" \
        | tee -a "$LOG_DIR/services.log" ;;
  esac
else
  overrides="${overrides}dwmapi=b"
fi
export WINEDLLOVERRIDES="${overrides};${GAME_DLL_EXTRA}"

SN2_CONTROL_WIN=$(winpath "$CONTROL_DIR")
SN2_DATA_WIN=$(winpath "$DATA_DIR")
SN2_SESSION_LIMIT=$SESSION_LIMIT
SN2_SAVE_WIN=$(winpath "$SAVE_DIR")
SN2_GAME_LOG_WIN=$(winpath "$UE_LOG")
SN2_HOST_NAME="${HOST_NAME:-SN2 Host}"
SN2_ADMINS="${ADMINS:-}"
SN2_ADMIN_PREFIX="${ADMIN_PREFIX:-!}"
SN2_HOST_STEAMID=$(host_steamid)
SN2_HIDE_HOST_BODY="${HIDE_HOST_BODY:-true}"
SN2_HOST_PRUNE="${HOST_PRUNE:-true}"
SN2_WORLD_NAME="$WORLD_NAME"
SN2_PLAYER_SLOTS=$PLAYER_SLOTS
SN2_STEAM_BRANCH="${STEAM_BRANCH:-public}"
SN2_GAME_BUILD_ID=$(vdf_get "$STEAM_DIR/steamapps/appmanifest_${GAME_APP_ID}.acf" buildid)
SN2_GAME_BUILD_ID="${SN2_GAME_BUILD_ID:-unknown}"
SN2_SAVE_NAME="${SAVE_NAME:-}"
SN2_IDLE_FREEZE_MINUTES="${IDLE_FREEZE_MINUTES:-10}"
SN2_IDLE_STOP_HOURS="${IDLE_STOP_HOURS:-}"
SN2_UNLOCK_INTERVAL_MS="${UNLOCK_INTERVAL_MS:-50}"
SN2_STORY_GOALS="$STORY_GOALS"
SN2_UNLOCK_REPLAY="$UNLOCK_REPLAY"
SN2_LIFEPOD_JOIN_HOLD="$LIFEPOD_JOIN_HOLD"
SN2_VOICE_WARN="$VOICE_WARN"
SN2_VOICE_RANGE_M="$VOICE_RANGE_M"
export SN2_CONTROL_WIN SN2_DATA_WIN SN2_SESSION_LIMIT SN2_SAVE_WIN SN2_GAME_LOG_WIN SN2_HOST_NAME SN2_WORLD_NAME \
  SN2_PLAYER_SLOTS SN2_STEAM_BRANCH SN2_SAVE_NAME SN2_IDLE_FREEZE_MINUTES SN2_IDLE_STOP_HOURS \
  SN2_UNLOCK_INTERVAL_MS SN2_HIDE_HOST_BODY SN2_HOST_PRUNE SN2_GAME_BUILD_ID SN2_HOST_STEAMID \
  SN2_STORY_GOALS SN2_UNLOCK_REPLAY SN2_LIFEPOD_JOIN_HOLD SN2_ADMINS SN2_ADMIN_PREFIX \
  SN2_VOICE_WARN SN2_VOICE_RANGE_M
if [ -n "$SAVE_NAME" ] && [ ! -f "$CONTROL_DIR/SAVE_SELECT" ]; then
  printf '%s\n' "$SAVE_NAME" >"$CONTROL_DIR/SAVE_SELECT"
fi

# shellcheck disable=SC2206  # NULLRHI_ARGS is a word list by design
args=($NULLRHI_ARGS "-port=$GAME_PORT")
case " ${args[*]} " in
  *" -nullrhi "*) ;;
  *) log "NULLRHI_ARGS lacks -nullrhi; adding it (no GPU here)"; args=(-nullrhi "${args[@]}") ;;
esac
if [ -f "$HOST_ARMED_FILE" ]; then
  log "HOST_ARMED present: the mod will call the game's Host code once ready"
else
  log "not armed: the mod idles in the lobby (moonpool server arm to host)"
fi

archive_previous_logs "$DATA_DIR/log-history" "$UE_LOG" "$WIN64_DIR/ue4ss/UE4SS.log" \
  "$(date -u +%Y%m%dT%H%M%SZ)-$$"
[ -f "$GAME_LOG" ] && mv -f "$GAME_LOG" "$GAME_LOG.prev"
# The headless window is always in the background, so its background frame cap is the one that counts.
SERVER_MAX_FPS="${SERVER_MAX_FPS:-60}"
GAME_USER_SETTINGS="${UE_LOG%/Logs/*}/Config/Windows/GameUserSettings.ini"
if ! set_background_fps "$GAME_USER_SETTINGS" "$SERVER_MAX_FPS"; then
  log "SERVER_MAX_FPS must be a positive integer"; exit 2
fi
log "background frame-rate limit: $SERVER_MAX_FPS"
[ -f "$WIN64_DIR/ue4ss/UE4SS.log" ] && mv -f "$WIN64_DIR/ue4ss/UE4SS.log" "$WIN64_DIR/ue4ss/UE4SS.log.prev"
apply_local_paks
# The last run's lobby is gone: a player sent to it gets "session is no longer available".
rm -f "$RUN_DIR/mod-session.json"; python3 "$(dirname "$0")/join-page.py" || true
log "launching: $GAME_EXE_NAME ${args[*]}" | tee -a "$GAME_LOG"
cd "$WIN64_DIR" || exit 1
"${WITHOUT_SECRETS[@]}" wine "$GAME_EXE_NAME" "${args[@]}" >>"$GAME_LOG" 2>&1 &
echo $! >"$GAME_PIDFILE"
# shellcheck disable=SC2329  # term_stop is invoked indirectly by trap
trap term_stop TERM INT
wait $!
status=$?
rm -f "$GAME_PIDFILE"  # the number can be another process's by the next stop
log "game process exited with status $status" | tee -a "$GAME_LOG"
exit "$status"
