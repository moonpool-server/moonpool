#!/usr/bin/env bash
# Scheduled restart (RESTART_CRON) through moonpool.
set -u
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

MOONPOOL="${MOONPOOL:-moonpool}"
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
