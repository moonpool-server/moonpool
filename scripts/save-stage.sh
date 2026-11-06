#!/usr/bin/env bash
# Offen/docker-volume-backup archives a folder; it cannot
# tell when the game has finished writing a save, so this stages a quiet copy.
# Copies the game's save folder plus the host account's Steam userdata for the
# game into $STAGING_DIR/<UTC timestamp>/, keeps the newest 3, and writes the
# outcome to $BACKUP_STATUS (shown on the viewer's status line by moonpool/x11vnc).
#   save-stage.sh            stage once if the saves have been quiet >= 60 s
#   save-stage.sh --now      stage now: on the game's autosave_completed log line
#                            (join-watch.sh) and before moonpool restore writes
# Trigger: the game logs "Queuing up event 'autosave_completed'" when an
# autosave finishes;
# quiet-for-60-s stays as the fallback if that line ever stops appearing.
set -u
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

QUIET=${SAVE_QUIET_SECS:-60}
KEEP=${STAGING_KEEP:-3}
status() {
  local was; was=$(cat "$BACKUP_STATUS" 2>/dev/null)
  printf '%s backup: %s\n' "$(date -u +%FT%TZ)" "$1" | tee "$BACKUP_STATUS" >>"$LOG_DIR/backup.log"
  # Entering or leaving a failure: restart the viewer so its page title says so.
  local a=ok b=ok
  case $was in *FAILED*) a=failed ;; esac
  case $1 in FAILED*) b=failed ;; esac
  [ "$a" = "$b" ] || s6-svc -r /run/service/sn2-x11vnc 2>/dev/null || true
}

[ -d "$SAVE_DIR" ] || { status "FAILED: save folder missing ($SAVE_DIR)"; exit 1; }
newest=$(find "$SAVE_DIR" -type f -name '*.sav' -printf '%T@\n' | sort -n | tail -1)
[ -n "$newest" ] || { status "nothing to stage: no .sav in $SAVE_DIR"; exit 0; }
last="$STAGING_DIR/.last-staged"
if [ "${1:-}" != --now ]; then
  age=$(( $(date +%s) - ${newest%.*} ))
  [ "$age" -ge "$QUIET" ] || exit 0                      # still being written
  [ "$(cat "$last" 2>/dev/null)" != "$newest" ] || exit 0 # already staged
fi

dest="$STAGING_DIR/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dest/userdata" || { status "FAILED: cannot create $dest"; exit 1; }
if ! cp -a "$SAVE_DIR" "$dest/SaveGames"; then
  rm -rf "$dest"; status "FAILED: copy of $SAVE_DIR (disk full?)"; exit 1
fi
for u in "$STEAM_DIR"/userdata/*/"$GAME_APP_ID"; do
  [ -d "$u" ] || continue
  acct=$(basename "$(dirname "$u")")
  cp -a "$u" "$dest/userdata/$acct" || { rm -rf "$dest"; status "FAILED: copy of Steam userdata"; exit 1; }
done
echo "$newest" >"$last"
# Keep the newest $KEEP; offen keeps the archives (BACKUP_RETENTION_DAYS).
find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n -"$KEEP" | xargs -r rm -rf
status "staged $(basename "$dest") ($(du -sh "$dest" | cut -f1))"
