#!/usr/bin/env bash
# Supercronic fires on time, but only the game log says when an
# autosave has finished; this waits for that line before restarting.
# Scheduled restart (RESTART_CRON, run by supercronic): wait for the game's next
# autosave to finish, then restart the session through moonpool. Gives up after
# RESTART_WAIT_MAX seconds (default 1800) and restarts anyway, saying so.
set -u
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

MOONPOOL="${MOONPOOL:-moonpool}"
# The receipt names who asked: this is the scheduled restart, nobody at a keyboard.
export SN2_SOURCE="${SN2_SOURCE:-automation}"
OUT="$LOG_DIR/cron.log"
mkdir -p "$LOG_DIR"
note() { printf '[%s] restart: %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT"; }

if [ -z "$(game_pid)" ] && [ -f "$RUN_DIR/idle-stopped" ]; then
  rm -f "$RUN_DIR/idle-stopped" "$STOP_FLAG"
  note "game was stopped for IDLE_STOP_HOURS; starting it again (lobby, then the host arms itself)"
  exit 0
fi
if [ -z "$(game_pid)" ]; then
  note "game not running; nothing to restart"
  exit 0
fi
note "scheduled restart requested"
"$MOONPOOL" server host
