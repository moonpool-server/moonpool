#!/usr/bin/env bash
# Read-only check, from its own logs, that a fresh install hosted by itself.
set -u
# shellcheck source=common.sh
. "${SN2_COMMON:-$(dirname "$0")/common.sh}"

json=0
[ "${1:-}" = --json ] && json=1
[ $# -le "$json" ] || { echo "usage: verify-fresh.sh [--json]" >&2; exit 2; }

SERVICES_LOG="$LOG_DIR/services.log"
UE4SS_LOG="$UE4SS_DIR/UE4SS.log"
# OnCreateSessionComplete and Load map complete are in the engine's own log, never game.log.
ENGINE_LOG="${ENGINE_LOG:-$UE_LOG}"
JOIN_LOG="$LOG_DIR/join_watch.log"
results="" failures=0

clean() { printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }
jescape() { clean "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
line_time() {
  local l=$1
  printf '%s\n' "$l" | sed -nE 's/^\[([^]]+)\].*/\1/p' | head -n1
}
file_time() { date -u -d "@$(stat -c %Y "$1")" +%FT%TZ 2>/dev/null || echo unknown; }
last_line() { grep -aE "$1" "$2" 2>/dev/null | tail -n1; }
record() {
  local id=$1 ok=$2 time=$3 proof=$4 status=PASS
  [ "$ok" = 1 ] || { status=FAIL; failures=$((failures + 1)); }
  time=${time:-unknown}; proof=$(clean "$proof")
  if [ "$json" = 1 ]; then
    results="$results${results:+,}{\"stage\":\"$(jescape "$id")\",\"status\":\"$status\",\"time\":\"$(jescape "$time")\",\"proof\":\"$(jescape "$proof")\"}"
  else
    printf '%s %s [%s] %s\n' "$status" "$id" "$time" "$proof"
  fi
}

# 1. Steam identity is proved by the service, not inferred from token files.
l=$(last_line 'Steam signed in: true ' "$SERVICES_LOG")
if [ -n "$l" ]; then record steam 1 "$(line_time "$l")" "$l"
else record steam 0 unknown "no 'Steam signed in: true' line in $SERVICES_LOG"; fi

# 2. Steam finished the configured branch and the branch-named executable exists.
exe="$WIN64_DIR/$GAME_EXE_NAME"
l=$(last_line ' installed$' "$SERVICES_LOG")
if [ -f "$exe" ] && [ -n "$l" ] && ! game_exe_mismatch >/dev/null; then
  record game 1 "$(line_time "$l")" "$l; $STEAM_BRANCH uses $GAME_EXE_NAME"
else
  record game 0 unknown "configured branch $STEAM_BRANCH needs $exe and an installed line in $SERVICES_LOG"
fi

# 3. The selected loader was staged, has its required signatures, and is one build.
loader_bad=""
for f in "$WIN64_DIR/dwmapi.dll" "$UE4SS_DIR/UE4SS.dll"; do [ -s "$f" ] || loader_bad="$loader_bad missing:$f"; done
if ue4ss_needs_layout_set; then
  for s in $UE4SS_SIGNATURES; do [ -s "$UE4SS_DIR/UE4SS_Signatures/$s.lua" ] || loader_bad="$loader_bad missing:$s"; done
fi
if [ -f "$exe" ] && [ -d "$UE4SS_DIR" ]; then
  # stat, not find -newermt: busybox (the bats image) has no -newermt.
  exe_t=$(stat -c %Y "$exe"); old=""
  while IFS= read -r f; do
    [ "$(stat -c %Y "$f")" -lt "$exe_t" ] && { old=$f; break; }
  done < <(find "$UE4SS_DIR" -type f 2>/dev/null)
  [ -z "$old" ] || loader_bad="$loader_bad older-than-exe:$old"
fi
l=$(last_line "UE4SS (installed for channel|.*channel) $(ue4ss_channel)" "$SERVICES_LOG")
[ -n "$l" ] || loader_bad="$loader_bad no-channel-install-line"
if [ -z "$loader_bad" ]; then record loader 1 "$(line_time "$l")" "$l; loader files are not older than $GAME_EXE_NAME"
else record loader 0 unknown "${loader_bad# }; checked $UE4SS_DIR"; fi

# 4. Pinned builds need an operator's layout set whose exe.sha256 is this exe, applied.
layout_bad=""; hash=""; l=""
if ue4ss_needs_layout_set; then
  [ -f "$exe" ] && hash=$(sha256sum "$exe" | cut -d' ' -f1)
  set_dir=""
  for d in "$UE4SS_LAYOUTS"/*/; do
    [ -n "$hash" ] && [ "$(tr -d ' \r\n' <"${d}exe.sha256" 2>/dev/null)" = "$hash" ] && { set_dir=${d%/}; break; }
  done
  [ -n "$set_dir" ] || layout_bad="$layout_bad no-layout-set-for:${hash:-no-exe}"
  for f in MemberVariableLayout.ini VTableLayout.ini; do
    if [ -n "$set_dir" ]; then
      cmp -s "$set_dir/$f" "$UE4SS_DIR/$f" || layout_bad="$layout_bad not-applied:$f"
    fi
  done
  l=$(last_line "UE4SS layout: operator set .* .exe sha256 $hash." "$SERVICES_LOG")
fi
if [ -z "$layout_bad" ]; then
  if [ -n "$l" ]; then record layout 1 "$(line_time "$l")" "$l"
  elif [ -n "${set_dir:-}" ]; then
    record layout 1 "$(file_time "$UE4SS_DIR/MemberVariableLayout.ini")" "set ${set_dir##*/} applied (exe sha256 $hash; both ini files byte-equal)"
  else record layout 1 "$(file_time "$exe")" "channel $(ue4ss_channel) needs no per-build layout for $GAME_EXE_NAME"; fi
else record layout 0 unknown "${layout_bad# }"; fi

# 5. UE4SS must get past its scan into mod startup and load ours.
loc=$(grep -anE 'Locating Kismet(String|System)Library' "$UE4SS_LOG" 2>/dev/null | tail -n1 | cut -d: -f1)
mods=$(grep -aniE 'start(ing|ed).*(lua )?mods|mods.*start(ing|ed)' "$UE4SS_LOG" 2>/dev/null | tail -n1)
loaded=$(grep -aniE 'SN2SlotFreeHost.*loaded|loaded.*SN2SlotFreeHost' "$UE4SS_LOG" 2>/dev/null | tail -n1)
mn=${mods%%:*}; ln=${loaded%%:*}
if [ -n "$loc" ] && [ -n "$mods" ] && [ -n "$loaded" ] && [ "$mn" -gt "$loc" ] && [ "$ln" -ge "$mn" ]; then
  proof=${loaded#*:}; record ue4ss 1 "$(line_time "$proof")" "$proof"
else record ue4ss 0 unknown "missing ordered scan -> mods starting -> SN2SlotFreeHost loaded evidence in $UE4SS_LOG"; fi

# 6. All session evidence must exist; the mod's own lines are in UE4SS.log.
session_bad=""; proof=""
specs=(
  "$SERVICES_LOG|AUTO_HOST: armed.*session limit $SESSION_LIMIT\)"
  "$ENGINE_LOG:$GAME_LOG:$UE4SS_LOG|OnCreateSessionComplete.*bWasSuccessful: 1"
  "$ENGINE_LOG:$GAME_LOG:$UE4SS_LOG|Load map complete.*/Game/Maps/Main/L_Main"
  "$UE4SS_LOG|\[SN2SlotFreeHost\] postmap: world GameSession.MaxPlayers [0-9]+ -> $SESSION_LIMIT([^0-9]|$)"
  "$UE4SS_LOG|\[SN2SlotFreeHost\] postmap: prune host PlayerState: ok"
  "$UE4SS_LOG|\[SN2SlotFreeHost\] hosted: Host call ok, session limit read back $SESSION_LIMIT([^0-9]|$)"
)
for spec in "${specs[@]}"; do
  p=${spec#*|}; x=""
  # ':'-separated: the logs live under "Program Files (x86)".
  IFS=: read -r -a files <<<"${spec%%|*}"
  for f in "${files[@]}"; do x=$(last_line "$p" "$f"); [ -n "$x" ] && break; done
  [ -n "$x" ] && proof=$x || session_bad="$session_bad missing:$p"
done
if [ -z "$session_bad" ]; then record session 1 "$(line_time "$proof")" "$proof"
else record session 0 unknown "${session_bad# }"; fi

# 7. The watcher writes UTC ISO heartbeats; only a recent RUNNING one proves it.
l=$(last_line 'heartbeat: game (alive|RUNNING)$' "$JOIN_LOG")
ts=$(line_time "$l"); # "2026-10-31T14:27:22Z" -> "2026-10-31 14:27:22": busybox date reads only the latter.
epoch=$(TZ=UTC date -d "$(printf '%s' "$ts" | sed 's/T/ /; s/Z$//')" +%s 2>/dev/null || echo 0); now=$(date +%s)
if [ -n "$l" ] && [ "$epoch" -gt 0 ] && [ $((now - epoch)) -ge 0 ] && [ $((now - epoch)) -le 300 ]; then
  record watcher 1 "$ts" "$l"
else record watcher 0 "${ts:-unknown}" "no RUNNING heartbeat within 5 minutes in $JOIN_LOG"; fi

# 8. The world hosted is the configured save. The mod's prints share one line, so the last slot token counts.
hosted=$(last_line 'SN2SlotFreeHost\] Host call: ServerName=.* SaveSlot=' "$UE4SS_LOG" | grep -oE 'Host call: ServerName=.* SaveSlot=[A-Za-z0-9_]+' | sed -E 's/.*SaveSlot=//' | tail -n1)
SAVE_SLOT="${SAVE_NAME:-${hosted:-Slot1}}"
l=$(last_line "LoadMap: /Game/Maps/Main/L_Main.*SaveSlotName=$SAVE_SLOT([^A-Za-z0-9_]|$)" "$ENGINE_LOG")
if [ -n "$l" ]; then record save 1 "$(line_time "$l")" "$l"
else record save 0 unknown "no LoadMap with SaveSlotName=$SAVE_SLOT in $ENGINE_LOG"; fi

# 9. The status card was edited (or posted) by the recipe's own Discord path.
DISCORD_LOG="$LOG_DIR/discord.log"
if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then record card 1 unknown "DISCORD_WEBHOOK_URL unset: no card expected"
else
  l=$(last_line 'discord: (PATCH|POST) [^ ]+ -> HTTP 2[0-9][0-9]' "$DISCORD_LOG")
  if [ -n "$l" ]; then record card 1 "$(line_time "$l")" "$l"
  else record card 0 unknown "no 2xx PATCH/POST in $DISCORD_LOG"; fi
fi

[ "$json" = 1 ] && printf '{"ok":%s,"stages":[%s]}\n' "$([ "$failures" -eq 0 ] && echo true || echo false)" "$results"
[ "$failures" -eq 0 ]
