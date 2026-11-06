#!/usr/bin/env bash
# The game has no RCON broadcast or shutdown hook; this coordinates its
# file-drop mod, save log and every local restart path.
set -u
. "$(dirname "$0")/common.sh"
SECONDS_TOTAL="${RESTART_WARNING_SECONDS:-120}"
SAVE_WAIT="${RESTART_SAVE_WAIT_SECONDS:-60}"
STATE="$RUN_DIR/restart-warning.json" CANCEL="$RUN_DIR/restart-warning.cancel" LOCK="$RUN_DIR/restart-warning.lock"
DONE="$RUN_DIR/restart-warning.done" RECEIPT="$RUN_DIR/restart-warning-receipt.json"
MOONPOOL="${MOONPOOL:-moonpool}"
mkdir -p "$RUN_DIR" "$CONTROL_DIR"
remaining() { local d; d=$(jq -r '.deadline // 0' "$STATE" 2>/dev/null || echo 0); echo $((d - $(date +%s))); }
case "${1:-run}" in
  cancel) if [ -f "$STATE" ]; then : >"$CANCEL"; echo "restart countdown cancelled"; else echo "no restart countdown is running"; fi; exit 0 ;;
  status) [ -f "$STATE" ] || exit 1; left=$(remaining); [ "$left" -gt 0 ] || left=0; echo "$left"; exit 0 ;;
  run) ;;
  *) echo 'usage: restart-warning.sh run [detail] | cancel | status' >&2; exit 64 ;;
esac
exec 8>"$LOCK"
if ! flock -n 8; then left=$(remaining); [ "$left" -gt 0 ] || left=0; echo "restart countdown already running; ${left}s left"; exit 75; fi
rm -f "$CANCEL"
if [ -f "$DONE" ] && [ $(( $(date +%s) - $(cat "$DONE" 2>/dev/null || echo 0) )) -lt 30 ]; then exit 0; fi
if ! session_up; then exit 0; fi
deadline=$(( $(date +%s) + SECONDS_TOTAL ))
jq -cn --argjson d "$deadline" --arg detail "${2:-restart requested}" '{deadline:$d,detail:$detail}' >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
trap 'rm -f "$STATE" "$CANCEL"' EXIT
"$(dirname "$0")/discord-notify.sh" event restart "${2:-restart requested}; <t:${deadline}:R>" >/dev/null 2>&1 || true
save_requested=false save_line=1 save_seen=''
# The mod only queues the game's async save, so completion is the game's own evidence: its
# autosave_completed log line, or a .sav whose timestamp changed since the request, compared as
# stat's full string: find -newer on busybox compares whole seconds and missed a same-second write.
save_stamp() { find "$SAVE_DIR" -type f -name '*.sav' -exec stat -c %y {} + 2>/dev/null | sort | tail -n1; }
save_done() { tail -n "+$save_line" "$UE_LOG" 2>/dev/null | grep -a -q -m1 autosave_completed || [ "$(save_stamp)" != "$save_seen" ]; }
request_save() {
  [ "$save_requested" = false ] || return 0
  save_line=$(( $(wc -l <"$UE_LOG" 2>/dev/null || echo 0) + 1 ))
  save_seen=$(save_stamp)
  save_requested=true
  # The internal restart-warning command already owns moonpool.lock on fd 9.
  # moonpool verifies both before letting this nested save share the parent lock.
  if save_receipt=$(SN2_LOCK_HELD=1 "$MOONPOOL" --json server save 2>&1); then
    echo "forced save requested: $save_receipt"
  else
    echo "forced save request failed: $save_receipt"
  fi
}
for mark in 120 60 30 10 0; do
  [ "$mark" -le "$SECONDS_TOTAL" ] || continue
  target=$((deadline - mark))
  while [ "$(date +%s)" -lt "$target" ]; do
    if [ -f "$CANCEL" ]; then
      jq -cn '{kind:"cancel",text:"Server restart cancelled"}' >"$CONTROL_DIR/notify-request.json.tmp" && mv "$CONTROL_DIR/notify-request.json.tmp" "$CONTROL_DIR/notify-request.json"
      echo "restart countdown cancelled"; exit 125
    fi
    sleep 1
  done
  if [ "$mark" -eq 0 ]; then
    request_save
    break
  fi
  if [ "$mark" -eq 60 ]; then header='Server restart in 1 minute'; elif [ "$mark" -eq 120 ]; then header='Server restart in 2 minutes'; else header="Server restart in ${mark} seconds"; fi
  jq -cn --arg h "$header" --arg t 'The world is saved first. Rejoin in a minute or two.' '{kind:"warning",header:$h,text:$t}' >"$CONTROL_DIR/notify-request.json.tmp" && mv "$CONTROL_DIR/notify-request.json.tmp" "$CONTROL_DIR/notify-request.json"
  [ "$mark" -ne 10 ] || request_save
done
save_completed=false
save_deadline=$(( $(date +%s) + SAVE_WAIT ))
while [ "$SAVE_WAIT" -gt 0 ]; do
  if save_done; then save_completed=true; break; fi
  [ "$(date +%s)" -lt "$save_deadline" ] || break
  sleep 1
done
if [ "$save_completed" = true ]; then
  final_text='The world is saved. Rejoin in a minute or two.'
  echo 'forced save completed before restart'
else
  final_text='Rejoin in a minute or two.'
  echo "forced save completion timed out after ${SAVE_WAIT}s"
fi
jq -cn --arg t "$final_text" '{kind:"warning",header:"Restarting now",text:$t}' >"$CONTROL_DIR/notify-request.json.tmp" && mv "$CONTROL_DIR/notify-request.json.tmp" "$CONTROL_DIR/notify-request.json"
jq -cn --argjson completed "$save_completed" --argjson wait "$SAVE_WAIT" \
  '{save_completed:$completed,save_wait_seconds:$wait,result:(if $completed then "saved" else "save_timeout" end)}' >"$RECEIPT.tmp" && mv "$RECEIPT.tmp" "$RECEIPT"
date +%s >"$DONE"
