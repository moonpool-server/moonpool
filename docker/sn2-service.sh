#!/usr/bin/env bash
# The per-service start commands (display, viewer, Windows Steam, game,
# join watcher) that s6-overlay supervises; it does not know what to run here.
# One foreground process per service name. The supervisor restarts it when it
# exits: s6-overlay (/etc/s6-overlay/s6-rc.d/<name>). Nothing here loops to
# restart anything; a service that is not ready yet exits and is started again.
#   xvfb x11vnc novnc clipboard clipboard-primary   the viewer
#   steam        Wine prefix, Windows Steam client, kept sign-in token
#   game         install, UE4SS, auto-arm, launch (exits when the game exits)
#   join-watch   join and slot lines from the game log
#   cron         RESTART_CRON and the admin's crontab through supercronic (idle when neither)
set -uo pipefail
# shellcheck source=../scripts/common.sh
. /opt/sn2/bin/common.sh

NOVNC_WEB="${NOVNC_WEB:-/usr/share/novnc}"
# noVNC shows the VNC desktop name as the page title, so the title names the step.
VIEWER_TITLE="${VIEWER_TITLE:-SN2 host - step 2: sign in to Steam here (tick Remember me)}"
# Our display is plain X and x11vnc refuses to start when it sees Wayland.
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

ensure_layout || exit 1
say() { log "$*" | tee -a "$LOG_DIR/services.log"; }
display_up() { xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; }
wait_display() {
  local _
  for _ in $(seq 1 30); do display_up && return 0; sleep 0.5; done
  say "$1: display $DISPLAY not up yet; the supervisor retries"
  sleep 5
  exit 1
}

# Steam's remembered-login token lives in the Wine profile's AppData/Local/Steam;
# keep it under the volume so a rebuilt image or prefix keeps the sign-in.
persist_steam_session() {
  local local_dir
  # Wine names the profile after $USER, so follow it rather than id -un.
  local_dir="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/AppData/Local"
  mkdir -p "$STEAM_SESSION_DIR" "$local_dir"
  chmod 0700 "$DATA_DIR/steam-session"
  if [ ! -L "$local_dir/Steam" ]; then
    if [ -d "$local_dir/Steam" ]; then
      cp -an "$local_dir/Steam/." "$STEAM_SESSION_DIR/"
      rm -rf "$local_dir/Steam"
    fi
    ln -s "$STEAM_SESSION_DIR" "$local_dir/Steam"
    say "Steam sign-in token kept in $STEAM_SESSION_DIR"
  fi
}

# The sign-in rule and what each Steam client build writes: steam_signed_in in
# scripts/common.sh. A client must be running for the account to count.
write_identity() {
  local signed=false
  # steam_signed_in sets the signal; with no client running it is never called, and
  # `set -u` otherwise stops the game service on every attempt until Steam is up.
  STEAM_SIGNIN_SIGNAL="Steam client not running"
  if steam_running && steam_signed_in; then
    signed=true
    rm -f "$RUN_DIR/steam-logged-off-restarted"
  elif [[ $STEAM_SIGNIN_SIGNAL == logged\ off:* ]]; then
    restart_steam_after_logoff "$STEAM_SIGNIN_SIGNAL" "$RUN_DIR/steam-logged-off-restarted" || true
  fi
  say_on_change steam-identity "Steam signed in: $signed ($STEAM_SIGNIN_SIGNAL)"
  printf '{"signed_in":%s,"ts":%s}\n' "$signed" "$(date +%s)" >"$CONTROL_DIR/tmp/identity.json"
  mv -f "$CONTROL_DIR/tmp/identity.json" "$CONTROL_DIR/steam_identity.json"
  [ "$signed" = true ]
}

svc_steam() {
  wait_display steam
  if [ ! -f "$WINEPREFIX/system.reg" ]; then
    say "creating Wine prefix in $WINEPREFIX (first start)"
    WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init >"$LOG_DIR/wineboot.log" 2>&1
    wineserver -w
  fi
  if [ ! -f "$STEAM_EXE" ]; then
    say "installing the Windows Steam client into the volume (first start)"
    mkdir -p "$DATA_DIR/cache"
    curl -fsSL -o "$DATA_DIR/cache/SteamSetup.exe" \
      https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe || { sleep 30; exit 1; }
    wine "$DATA_DIR/cache/SteamSetup.exe" /S >"$LOG_DIR/steam-setup.log" 2>&1 || true
    wineserver -w
    if [ ! -f "$STEAM_EXE" ] && [ -f "$STEAM_DIR/Steam.exe" ]; then ln -sfn Steam.exe "$STEAM_EXE"; fi
    [ -f "$STEAM_EXE" ] || { say "Steam install did not produce steam.exe; see $LOG_DIR/steam-setup.log"; sleep 30; exit 1; }
  fi
  persist_steam_session
  /opt/sn2/bin/steam-config.sh || { say "steam-config refused the settings; see $LOG_DIR"; sleep 30; exit 1; }
  # steam.exe hands off to a client that is already running and exits at once,
  # so the supervisor reran this every second and logged the start line each
  # time (373 lines in 7 minutes). Start one client,
  # wait on the one that runs, and log only when that state changes.
  if steam_running; then
    say_on_change steam-client "Windows Steam client running; sign in on the viewer page if it asks"
    while steam_running; do sleep 5; done
    say_on_change steam-client "Windows Steam client exited; the supervisor starts it again"
    exit 0
  fi
  if ! save_copy_before_update; then
    say_on_change steam-client "Steam not started: it can update the game and the save copy failed; see logs/save-stage.log, or set UPDATE_WITHOUT_BACKUP=true"
    sleep 30; exit 1
  fi
  say_on_change steam-client "starting the Windows Steam client; sign in on the viewer page"
  wine "$STEAM_EXE" -no-browser -silent >>"$LOG_DIR/steam.log" 2>&1
  sleep 5
  while steam_running; do sleep 5; done
  say_on_change steam-client "Windows Steam client exited; the supervisor starts it again"
}

svc_game() {
  if [ -f "$STOP_FLAG" ]; then
    local note
    note=$(stopped_notice "$STOP_FLAG" "$RUN_DIR/stopped-noted" "$(container_start)") && [ -n "$note" ] && say "$note"
    sleep 10; exit 0
  fi
  if ! write_identity; then sleep 10; exit 0; fi
  # Installed is Steam's own record (game_install_state in common.sh), never the
  # executable alone: Steam preallocates it when the download starts. While the
  # game is not installed this service exits after 30 s and the supervisor runs
  # it again, so the launch follows the install in the same container run
  # because an install can finish without launching the game.
  local state mismatch
  # Never launch a build that is not the configured branch's: it can crash, and players
  # must be on the host's branch anyway.
  if mismatch=$(game_exe_mismatch); then
    say_on_change install "$mismatch; not launching, switching Steam to $STEAM_BRANCH"
    # steam-config sets the branch when the client next starts: restart it once, not while it downloads.
    if [ "$(vdf_get "$STEAM_DIR/steamapps/appmanifest_${GAME_APP_ID}.acf" BetaKey)" != "${STEAM_BRANCH#public}" ]; then
      wine "$STEAM_EXE" -shutdown >>"$LOG_DIR/steam.log" 2>&1 || true
    fi
    sleep 30; exit 0
  fi
  state=$(game_install_state)
  if [ "$state" != installed ]; then
    case $state in
      installing*) install_progress "$state" ;;
      *)
        # Not taken yet: ask on every start, and every 10 min within one, until
        # Steam starts the download.
        local asked="$RUN_DIR/install-asked"
        if [ ! -f "$asked" ] || [ "$(stat -c %Y "$asked")" -lt "$(container_start)" ] \
           || [ $(($(date +%s) - $(stat -c %Y "$asked"))) -ge 600 ]; then
          : >"$asked"
          /opt/sn2/bin/install-game.sh || say "install-game exited with $?"
        fi
        say_on_change install "game not installed yet; asked Steam to install it (see logs/install-confirm.log)" ;;
    esac
    sleep 30; exit 0
  fi
  say_on_change install installed
  # A failed loader install never stops the launch: the game starts without
  # UE4SS (launch-headless.sh logs why and what waits for it) and the install
  # is tried again on the next launch.
  if ue4ss_install_step /opt/sn2/bin/install-ue4ss.sh; then
    say "UE4SS installed for channel $(ue4ss_channel)"
  else
    say "UE4SS install failed: $(cat "$UE4SS_FAILED_FILE"); launching without the loader"
  fi
  # A build with no shipped layout set starts without the loader and is never
  # armed (install-ue4ss.sh fails closed); the mod's readiness checks are the
  # smoke check before its Host call.
  local mode
  mode=$(ue4ss_launch_mode "$WIN64_DIR")
  if [ "$mode" != loader ]; then
    rm -f "$HOST_ARMED_FILE"
    say "not arming: the loader is held back (${mode#held })"
  elif [ "$AUTO_HOST" = true ] && [ ! -f "$HOST_DISARMED_FILE" ]; then
    # Written on EVERY launch, not only when absent: the working host's script
    # never wrote it and a relaunch sat idle for 9 minutes.
    : >"$HOST_ARMED_FILE"
    say "AUTO_HOST: armed; the mod hosts once the lobby is reached ($PLAYER_SLOTS player slots, session limit $SESSION_LIMIT)"
  fi
  say_on_change install launching
  # A game that dies within 60 s is backed off (30 s, 60, 120 ... 10 min) with
  # the last three game-log lines logged once per backoff; otherwise it can relaunch
  # every ~14 s with none.
  local t0 rc ran wait_s
  t0=$(date +%s)
  /opt/sn2/bin/launch-headless.sh; rc=$?
  ran=$(($(date +%s) - t0))
  wait_s=$(crash_backoff "$ran" "$RUN_DIR/crash-backoff")
  if [ "$wait_s" -gt 0 ]; then
    say "game exited (status $rc) after ${ran}s; next launch in ${wait_s}s. Last game-log lines:"
    tail -n 3 "$GAME_LOG" 2>/dev/null | while IFS= read -r l; do say "  $l"; done
    sleep "$wait_s"
  fi
  exit "$rc"
}

name=${1:?usage: sn2-service.sh <service>}
case $name in
  xvfb)
    rm -f "/tmp/.X${DISPLAY#:}-lock" "/tmp/.X11-unix/X${DISPLAY#:}"
    exec Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp >>"$LOG_DIR/xvfb.log" 2>&1 ;;
  x11vnc)
    wait_display x11vnc
    # Always a password (common.sh viewer_password): moonpool diag viewer shows it.
    pw=$(viewer_password) || { say "viewer not started: could not make a password"; exec sleep infinity; }
    x11vnc -storepasswd "$pw" "$RUN_DIR/vncpass" >/dev/null 2>&1
    chmod 0600 "$RUN_DIR/vncpass"
    auth=(-rfbauth "$RUN_DIR/vncpass")
    [ -n "${VNC_PASSWORD:-}" ] || say_on_change viewer-password "viewer password made at first start; moonpool diag viewer shows it"
    # A failed backup is shown on the page title (the viewer's status line).
    if grep -q FAILED "$BACKUP_STATUS" 2>/dev/null; then
      VIEWER_TITLE="SN2 host - $(cut -c1-90 "$BACKUP_STATUS")"
    fi
    # x11vnc carries the VNC clipboard to the X selections by default.
    exec x11vnc -display "$DISPLAY" -forever -shared -localhost -rfbport "$VNC_PORT" \
      -desktop "$VIEWER_TITLE" "${auth[@]}" >>"$LOG_DIR/x11vnc.log" 2>&1 ;;
  novnc)
    # This viewer controls a signed-in Steam: it always asks for the password x11vnc holds.
    exec websockify --web "$NOVNC_WEB" "$NOVNC_PORT" "localhost:$VNC_PORT" >>"$LOG_DIR/novnc.log" 2>&1 ;;
  clipboard | clipboard-primary)
    [ "$CLIPBOARD_BRIDGE" = true ] || exec sleep infinity
    wait_display "$name"
    sel=CLIPBOARD; [ "$name" = clipboard-primary ] && sel=PRIMARY
    exec autocutsel -selection "$sel" >>"$LOG_DIR/clipboard.log" 2>&1 ;;
  steam) svc_steam ;;
  game) svc_game ;;
  join-watch) exec /opt/sn2/bin/join-watch.sh ;;
  mods)
    # The player web root on SN2_MODS_PORT: the join page, the map, the signed mod
    # manifest and launcher, and the tunnel's origin. Read-only, no listing;
    # mod-service.sh runs lighttpd and republishes the manifest from plugins.yaml.
    exec /opt/sn2/bin/mod-service.sh serve ;;
  cron)
    # Both are opt-in; a restart waits for an autosave. A broken admin file is said and skipped.
    : >"$RUN_DIR/crontab"
    [ -z "${RESTART_CRON:-}" ] || printf '%s /opt/sn2/bin/restart-after-autosave.sh\n' "$RESTART_CRON" >>"$RUN_DIR/crontab"
    if [ -s "$DATA_DIR/crontab" ]; then
      if supercronic -test "$DATA_DIR/crontab" >>"$LOG_DIR/cron.log" 2>&1; then cat "$DATA_DIR/crontab" >>"$RUN_DIR/crontab"
      else echo "crontab in the data volume is not valid; skipped" >>"$LOG_DIR/cron.log"; fi
    fi
    [ -s "$RUN_DIR/crontab" ] || exec sleep infinity
    exec supercronic "$RUN_DIR/crontab" >>"$LOG_DIR/cron.log" 2>&1 ;;
  *) echo "sn2-service.sh: unknown service $name" >&2; exit 64 ;;
esac
