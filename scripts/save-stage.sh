#!/usr/bin/env bash
# The backup sidecar cannot tell when a save is finished, so this stages a quiet copy of the saves
# and the game's Steam userdata in $STAGING_DIR/<UTC timestamp>/ and keeps the newest 3.
#   save-stage.sh         stage if the saves have been quiet for 60 s
#   save-stage.sh --now   stage now (after an autosave, and before a restore)
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

if [ ! -d "$SAVE_DIR" ]; then
  # A fresh install has no save folder until the game first saves; once copies exist, a missing one is a fault.
  if [ -z "$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -name '20*' 2>/dev/null | head -1)" ]; then
    status "nothing to stage: no world saved yet"; exit 0
  fi
  status "FAILED: save folder missing ($SAVE_DIR)"; exit 1
fi
mkdir -p "$STAGING_DIR" || { status "FAILED: cannot create $STAGING_DIR"; exit 1; }
# One staging at a time: the join watcher, the autosave hook and moonpool can all start one.
# fd 7, because moonpool hands its own lock to helpers on fd 9.
exec 7>"$STAGING_DIR/.stage.lock"
flock -x 7 || { status "FAILED: cannot lock $STAGING_DIR"; exit 1; }
newest=$(find "$SAVE_DIR" -type f -name '*.sav' -printf '%T@\n' | sort -n | tail -1)
[ -n "$newest" ] || { status "nothing to stage: no .sav in $SAVE_DIR"; exit 0; }
last="$STAGING_DIR/.last-staged"
if [ "${1:-}" != --now ]; then
  age=$(( $(date +%s) - ${newest%.*} ))
  [ "$age" -ge "$QUIET" ] || exit 0                      # still being written
  [ "$(cat "$last" 2>/dev/null)" != "$newest" ] || exit 0 # already staged
fi

# Copy into a private folder, then rename it into place, so a timestamped folder is always whole.
rm -rf "$STAGING_DIR"/.stage.*/ # left by a run that was killed; the lock says none is running
tmp=$(mktemp -d "$STAGING_DIR/.stage.XXXXXX") || { status "FAILED: cannot create a folder in $STAGING_DIR"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/userdata" || { status "FAILED: cannot create $tmp/userdata"; exit 1; }
if ! cp -a "$SAVE_DIR" "$tmp/SaveGames"; then
  status "FAILED: copy of $SAVE_DIR (disk full?)"; exit 1
fi
for u in "$STEAM_DIR"/userdata/*/"$GAME_APP_ID"; do
  [ -d "$u" ] || continue
  acct=$(basename "$(dirname "$u")")
  cp -a "$u" "$tmp/userdata/$acct" || { status "FAILED: copy of Steam userdata"; exit 1; }
done
# The name has one-second precision: a second staging in the same second waits for the next.
dest="$STAGING_DIR/$(date -u +%Y%m%dT%H%M%SZ)"
while [ -e "$dest" ]; do sleep 1; dest="$STAGING_DIR/$(date -u +%Y%m%dT%H%M%SZ)"; done
mv -T "$tmp" "$dest" || { status "FAILED: cannot rename $tmp to $dest"; exit 1; }
echo "$newest" >"$last"
# Keep the newest $KEEP; offen keeps the archives (BACKUP_RETENTION_DAYS).
find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n -"$KEEP" | xargs -r rm -rf
status "staged $(basename "$dest") ($(du -sh "$dest" | cut -f1))"
