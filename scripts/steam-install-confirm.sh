#!/usr/bin/env bash
# steam://install opens Steam's confirmation window and waits for a click, so this presses the
# install and location windows' default buttons with xdotool until the manifest appears. A licence
# window is named in the log but never pressed: agreeing to terms is a person's act.
set -uo pipefail

if [ "${SN2_CONFIRM_LIB:-0}" != "1" ]; then
  # shellcheck source=scripts/common.sh
  . "$(dirname "$0")/common.sh"
fi
CONFIRM_INTERVAL="${CONFIRM_INTERVAL:-10}"
CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-300}"
CONFIRM_LOG="${CONFIRM_LOG:-${LOG_DIR:-${DATA_DIR:-/home/container}/logs}/install-confirm.log}"
mkdir -p "$(dirname "$CONFIRM_LOG")" 2>/dev/null || true

# Titles of the windows between steam://install and a download, matched loosely on purpose.
CONFIRM_TITLES='^install( - .*)?$|- install$|^install .*|disk space|choose (a )?location|install location|license agreement|end user license|eula'

# The words a title must never carry (the main Steam window, the sign-in page).
CONFIRM_SKIP='^steam$|sign in|log ?in|friends'

# Prints the step a window title belongs to, or nothing when it is not one.
match_title() {
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ -n "$t" ] || return 1
  printf '%s' "$t" | grep -Eq "$CONFIRM_SKIP" && return 1
  printf '%s' "$t" | grep -Eq "$CONFIRM_TITLES" || return 1
  case $t in
    *licen* | *eula*) echo eula ;;
    *disk* | *location*) echo location ;;
    *) echo install ;;
  esac
}

clog() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$CONFIRM_LOG"; }

CONFIRM_SEEN="${CONFIRM_SEEN:-}"

# Clicks the primary button of window $1 at its measured relative position.
click_primary() {
  local WIDTH HEIGHT
  eval "$(timeout 5 xdotool getwindowgeometry --shell "$1" 2>/dev/null | grep -E '^(WIDTH|HEIGHT)=[0-9]+$')"
  [ -n "${WIDTH:-}" ] && [ -n "${HEIGHT:-}" ] || return 1
  timeout 5 xdotool mousemove --window "$1" $((WIDTH * 39 / 100)) $((HEIGHT * 91 / 100)) click 1 2>/dev/null
}

# One pass over the matching windows; returns 0 when it pressed something.
confirm_once() {
  local id title step pressed=1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    title=$(xdotool getwindowname "$id" 2>/dev/null) || continue
    step=$(match_title "$title") || continue
    if [ "$step" = eula ]; then
      if [[ " $CONFIRM_SEEN " != *" $id "* ]]; then
        clog "attempt $ATTEMPT: licence window '$title' (id $id) left for a person on the viewer; nothing here agrees to terms"
        CONFIRM_SEEN="$CONFIRM_SEEN $id"
      fi
      continue
    fi
    # The panel image runs no window manager, so a window that will not activate is focused instead.
    # Steam's dialogs are web views that may ignore Enter: a window still open gets one click.
    if [[ " $CONFIRM_SEEN " == *" $id "* ]] && click_primary "$id"; then
      clog "attempt $ATTEMPT: clicked the primary button of $step window '$title' (id $id)"
      pressed=0
    elif { timeout 5 xdotool windowactivate --sync "$id" 2>/dev/null ||
      timeout 5 xdotool windowfocus --sync "$id" 2>/dev/null; } &&
      timeout 5 xdotool key --window "$id" Return 2>/dev/null; then
      clog "attempt $ATTEMPT: pressed Enter on $step window '$title' (id $id)"
      CONFIRM_SEEN="$CONFIRM_SEEN $id"
      pressed=0
    else
      clog "attempt $ATTEMPT: found $step window '$title' (id $id) but could not focus it"
    fi
  done < <(xdotool search --onlyvisible --name '.' 2>/dev/null)
  return $pressed
}

# steam-config.sh may seed a manifest, so only Steam's own "StateFlags" line counts.
manifest_present() {
  local m="${STEAM_DIR:-/nonexistent}/steamapps/appmanifest_${GAME_APP_ID:-1962700}.acf"
  [ -f "$m" ] && grep -q '"StateFlags"' "$m"
}

confirm_loop() {
  local start now
  start=$(date +%s); ATTEMPT=0
  clog "start: watching DISPLAY=${DISPLAY:-unset} for Steam's install windows (every ${CONFIRM_INTERVAL}s, up to ${CONFIRM_TIMEOUT}s)"
  while :; do
    ATTEMPT=$((ATTEMPT + 1))
    if manifest_present; then clog "attempt $ATTEMPT: manifest present; Steam took the install"; return 0; fi
    confirm_once || clog "attempt $ATTEMPT: no install window on ${DISPLAY:-unset}"
    now=$(date +%s)
    if [ $((now - start)) -ge "$CONFIRM_TIMEOUT" ]; then
      clog "gave up after ${CONFIRM_TIMEOUT}s without a manifest; the next start asks again"
      return 1
    fi
    sleep "$CONFIRM_INTERVAL"
  done
}

# shellcheck disable=SC2317  # exit is reached only when the file is run, not sourced
if [ "${SN2_CONFIRM_LIB:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi
command -v xdotool >/dev/null 2>&1 || { clog "xdotool not installed; confirm Steam's install window on the viewer page"; exit 1; }
confirm_loop
