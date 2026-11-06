#!/usr/bin/env bash
# A health rule tied to Windows Steam and the game under Wine; Docker has no
# generic one.
# Container health: healthy when the Windows Steam client runs and, once the
# game is installed and not stopped by an admin, the game process runs.
# It never claims a session is hosted: only a second account joining proves that.
set -u
# shellcheck source=../scripts/common.sh
. /opt/sn2/bin/common.sh

if ! steam_running; then
  echo "unhealthy: Windows Steam client not running"
  exit 1
fi
if [ -f "$WIN64_DIR/$GAME_EXE_NAME" ] && [ ! -f "$STOP_FLAG" ] && [ -z "$(game_pid)" ]; then
  echo "unhealthy: game installed but not running"
  exit 1
fi
echo "healthy"
exit 0
