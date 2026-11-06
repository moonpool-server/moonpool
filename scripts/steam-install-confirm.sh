#!/usr/bin/env bash
# Steam://install opens Steam's own confirmation window
# and waits for a click; nothing upstream presses it headless, so this drives
# that window with xdotool (the standard X automation tool) on the client's display.
#
# During initial installation, the
# request opened Steam's "Install" window and the recipe waited for a click
# that never came. This finds Steam's install, disk-space/location and licence
# (EULA) windows by title on $DISPLAY, activates each and presses its default
# button (Enter), every CONFIRM_INTERVAL s until the game's manifest appears or
# CONFIRM_TIMEOUT s pass. steam://install stays the only request path: no
# second sign-in and no steamcmd.
set -uo pipefail

if [ "${SN2_CONFIRM_LIB:-0}" != "1" ]; then
  # shellcheck source=scripts/common.sh
  . "$(dirname "$0")/common.sh"
fi
CONFIRM_INTERVAL="${CONFIRM_INTERVAL:-10}"
CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-300}"
# Always under the data volume's logs/ as the docs say; the folder is made here,
# not assumed.
CONFIRM_LOG="${CONFIRM_LOG:-${LOG_DIR:-${DATA_DIR:-/home/container}/logs}/install-confirm.log}"
mkdir -p "$(dirname "$CONFIRM_LOG")" 2>/dev/null || true

# Titles of the Steam windows that stand between steam://install and a download
# (case-insensitive, extended regex). Unverified against the current client's
# exact wording: the receipt names only "Install"; the rest are Steam's
# usual dialog titles, matched loosely on purpose.
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

# Windows already sent Enter in an earlier pass (space-separated ids).
CONFIRM_SEEN="${CONFIRM_SEEN:-}"

# Clicks the primary button of window $1 at its measured relative position.
click_primary() {
  local WIDTH HEIGHT
  eval "$(timeout 5 xdotool getwindowgeometry --shell "$1" 2>/dev/null | grep -E '^(WIDTH|HEIGHT)=[0-9]+$')"
  [ -n "${WIDTH:-}" ] && [ -n "${HEIGHT:-}" ] || return 1
  timeout 5 xdotool mousemove --window "$1" $((WIDTH * 39 / 100)) $((HEIGHT * 91 / 100)) click 1 2>/dev/null
}

# One pass: every visible window on $DISPLAY whose title matches gets activated
# and its default button pressed. Returns 0 when it pressed something.
confirm_once() {
  local id title step pressed=1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    title=$(xdotool getwindowname "$id" 2>/dev/null) || continue
    step=$(match_title "$title") || continue
    # windowactivate needs a window manager and the panel image runs none, so bound both
    # calls and focus the window directly when activation does not take.
    # Steam's dialogs are web views that ignore Enter, so a window still open on a later
    # pass gets one click on its primary button: 39% across, 91% down the Install dialog.
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

# Steam took the install once the manifest carries its own "StateFlags" line.
# steam-config.sh may seed a manifest with only the beta opt-in before the
# request, so the file existing is not enough.
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
