#!/usr/bin/env bash
# Ask the running Windows Steam client to install (or update) the game into
# the volume, using its own download. No SteamCMD and no password: the client
# must already be signed in through the noVNC page (docs/operating.md).
set -euo pipefail
# shellcheck source=common.sh
. /opt/sn2/bin/common.sh

if ! steam_running; then
  log "install-game: the Steam client is not running"
  exit 1
fi

manifest="$STEAM_DIR/steamapps/appmanifest_${GAME_APP_ID}.acf"
if [ -f "$WIN64_DIR/$GAME_EXE_NAME" ]; then
  if [ "$AUTO_UPDATE" = "true" ]; then
    # A new build is matched to a shipped layout by its sha256, else it runs without the loader.
    if ! save_copy_before_update; then
      log "install-game: no save copy, so no update; see save-stage.log or set UPDATE_WITHOUT_BACKUP=true"
      exit 0
    fi
    log "install-game: AUTO_UPDATE=true, Steam validates and updates app $GAME_APP_ID"
    "${WITHOUT_SECRETS[@]}" wine "$STEAM_EXE" "steam://validate/$GAME_APP_ID" >>"$LOG_DIR/steam.log" 2>&1 &
  else
    log "install-game: game present; AUTO_UPDATE=false asks for no validation, but the Steam client can still update it"
  fi
  exit 0
fi

if [ "$STEAM_BRANCH" != "public" ] && [ -n "${STEAM_BRANCH_PASSWORD:-}" ]; then
  # Handed to the client once; it stores what it needs. Never written by us.
  "${WITHOUT_SECRETS[@]}" wine "$STEAM_EXE" "steam://setbeta/$GAME_APP_ID/$STEAM_BRANCH/$STEAM_BRANCH_PASSWORD" >/dev/null 2>&1 &
fi
log "install-game: asking Steam to install app $GAME_APP_ID (watch progress on the noVNC page)"
"${WITHOUT_SECRETS[@]}" wine "$STEAM_EXE" "steam://install/$GAME_APP_ID" >>"$LOG_DIR/steam.log" 2>&1 &
# The client shows its install (and maybe location and licence) windows; press
# their default buttons on the client's display, every 10 s for up to 5 min.
if "$(dirname "$0")/steam-install-confirm.sh"; then
  log "install-game: Steam took the install ($manifest); the download runs on its own"
else
  log "install-game: Steam has not taken the install yet; see $LOG_DIR/install-confirm.log (the next start asks again)"
fi
