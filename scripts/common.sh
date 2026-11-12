#!/usr/bin/env bash
# The defaults every script shares. Everything persistent lives under $DATA_DIR, the one volume.
# shellcheck disable=SC2034  # variables here are used by the scripts that source this file

DATA_DIR="${DATA_DIR:-/data}"
GAME_USER="${GAME_USER:-${USER:-container}}"
export WINEPREFIX="${WINEPREFIX:-$DATA_DIR/wine}"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export DISPLAY="${DISPLAY:-:99}"

GAME_APP_ID="${GAME_APP_ID:-${STEAM_APPID:-1962700}}"
# Nothing listens on it: players join through the game's own peer session.
GAME_PORT="${GAME_PORT:-7777}"
# PRESET supplies defaults only. A non-empty explicitly supplied setting wins;
# an empty value is the panel-friendly way to request the preset default.
PRESET="${PRESET:-friends}"
case "$PRESET" in
  friends|stock) ;;
  *) printf 'unknown PRESET %q (expected friends or stock)\n' "$PRESET" >&2; exit 64 ;;
esac
resolve_preset() {
  local name="$1" friends="$2" stock="$3"
  if [ -z "${!name-}" ]; then
    if [ "$PRESET" = stock ]; then printf -v "$name" %s "$stock"; else printf -v "$name" %s "$friends"; fi
  fi
  export "${name?}"
}
resolve_preset PLAYER_SLOTS 4 4
resolve_preset STORY_GOALS true false
resolve_preset UNLOCK_REPLAY true false
resolve_preset LIFEPOD_JOIN_HOLD true false
resolve_preset VOICE_WARN true false
resolve_preset IDLE_FREEZE_MINUTES 10 0
resolve_preset IDLE_STOP_HOURS '' ''
HOST_PRUNE="${HOST_PRUNE:-true}"
HIDE_HOST_BODY="${HIDE_HOST_BODY:-true}"
AUTO_ACCEPT_FRIENDS="${AUTO_ACCEPT_FRIENDS:-0}"
RESTART_CRON="${RESTART_CRON:-}"
RESTART_WARNING_SECONDS="${RESTART_WARNING_SECONDS:-120}"
RESTART_SAVE_WAIT_SECONDS="${RESTART_SAVE_WAIT_SECONDS:-60}"
export PRESET HOST_PRUNE HIDE_HOST_BODY AUTO_ACCEPT_FRIENDS RESTART_CRON RESTART_WARNING_SECONDS RESTART_SAVE_WAIT_SECONDS
VOICE_RANGE_M="${VOICE_RANGE_M:-100}"
export VOICE_RANGE_M VOICE_WARN

# The host account counts as a player, so the session limit is PLAYER_SLOTS + 1.
PLAYER_SLOTS="${PLAYER_SLOTS//[^0-9]/}"
SESSION_LIMIT=$((${PLAYER_SLOTS:-4} + 1))
HOST_NAME="${HOST_NAME:-SN2 Host}"
STEAM_BRANCH="${STEAM_BRANCH:-public}"
# Empty SAVE_NAME = newest save, or a new world (Slot1) when none exists.
SAVE_NAME="${SAVE_NAME:-}"
WORLD_NAME="${WORLD_NAME:-Subnautica 2 server}"
# No -nosound: with it a joining player's voice event is invalid and the game crashed on every join.
NULLRHI_ARGS="${NULLRHI_ARGS:--nullrhi -unattended -log}"
# UE4SS loads through its dwmapi.dll proxy at process start (WINEDLLOVERRIDES dwmapi=n,b).
UE4SS_AT_START="${UE4SS_AT_START:-true}"
# Microsoft's C++ runtime for the game process only.
NATIVE_MSVC="${NATIVE_MSVC:-1}"
MSVC_DLLS="msvcp140.dll vcruntime140.dll vcruntime140_1.dll msvcp140_atomic_wait.dll msvcp140_1.dll msvcp140_codecvt_ids.dll vccorlib140.dll"
NOVNC_PORT="${NOVNC_PORT:-8080}"
VNC_PORT="${VNC_PORT:-5900}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"

STEAM_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
STEAM_EXE="$STEAM_DIR/steam.exe"
GAME_DIR="${GAME_DIR:-$STEAM_DIR/steamapps/common/Subnautica2}"
WIN64_DIR="$GAME_DIR/Subnautica2/Binaries/Win64"
exe_for_branch() {
  case $1 in
    experimental) echo Subnautica2-Win64-Test.exe ;;
    *) echo Subnautica2-Win64-Shipping.exe ;;
  esac
}
GAME_EXE_NAME="${GAME_EXE_NAME:-$(exe_for_branch "$STEAM_BRANCH")}"
# The game's own Unreal log: the Test build writes it beside the game, the Shipping build in the
# Wine user's AppData. Wine names the profile after $USER, set even for a uid with no passwd entry.
ue_log_for_exe() {
  case $1 in
    *-Shipping.exe) echo "$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/AppData/Local/Subnautica2/Saved/Logs/Subnautica2.log" ;;
    *) echo "$GAME_DIR/Subnautica2/Saved/Logs/Subnautica2.log" ;;
  esac
}
UE_LOG="${UE_LOG:-$(ue_log_for_exe "$GAME_EXE_NAME")}"
set_ini_key() { # ini section key value: rewrite the key's line, else append it under its section
  local ini=$1 section=$2 key=$3 value=$4
  mkdir -p "${ini%/*}"
  if grep -q "^$key=" "$ini" 2>/dev/null; then sed -i "s|^$key=.*|$key=$value|" "$ini"
  else printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >>"$ini"; fi
}
set_background_fps() {
  case $2 in '' | *[!0-9]* | 0) return 2 ;; esac
  set_ini_key "$1" /Script/Subnautica2.SN2SettingsLocal FrameRateLimit_WhenBackgrounded "$2"
}
# Prints the mismatch line when only the other branch's executable is installed.
game_exe_mismatch() {
  local dir="${1:-$WIN64_DIR}" other=experimental
  [ -f "$dir/$(exe_for_branch "$STEAM_BRANCH")" ] && return 1
  [ "$STEAM_BRANCH" = experimental ] && other=public
  [ -f "$dir/$(exe_for_branch "$other")" ] || return 1
  echo "installed build is $other, STEAM_BRANCH says $STEAM_BRANCH"
}
UE4SS_DIR="$WIN64_DIR/ue4ss"
# The saves follow the executable the way its log does.
save_dir_for_exe() {
  case $1 in
    *-Shipping.exe) echo "$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/AppData/Local/Subnautica2/Saved/SaveGames" ;;
    *) echo "$GAME_DIR/Subnautica2/Saved/SaveGames" ;;
  esac
}
SAVE_DIR="${SAVE_DIR:-$(save_dir_for_exe "$GAME_EXE_NAME")}"
# The join watcher copies quiet saves here; the backup sidecar archives this folder, never the live one.
STAGING_DIR="$DATA_DIR/backup-staging"
# A save copy before anything that can update the game, since a new build can't be undone.
save_copy_before_update() {
  [ -d "$SAVE_DIR" ] && [ "${UPDATE_WITHOUT_BACKUP:-false}" != true ] || return 0
  "${SN2_BIN:-/opt/sn2/bin}/save-stage.sh" --now >>"$LOG_DIR/save-stage.log" 2>&1
}
BACKUP_STATUS="$DATA_DIR/backup-status.txt"

LOG_DIR="$DATA_DIR/logs"
RUN_DIR="$DATA_DIR/run"
CONTROL_DIR="${SN2_CONTROL_DIR:-${CONTROL_DIR:-$DATA_DIR/control}}"
# The mod calls the game's Host code only while this file exists. AUTO_HOST writes it on every
# launch unless `moonpool server disarm` left HOST_DISARMED.
HOST_ARMED_FILE="$CONTROL_DIR/HOST_ARMED"
AUTO_HOST="${AUTO_HOST:-true}"
# The lifepod launch cinematic crashes the game inside Wine's xaudio2 (FAudioVoice_GetVoiceDetails).
GAME_DLL_EXTRA="${GAME_DLL_EXTRA:-xaudio2_9=d}"
line_shows_player_join() {
  [[ $1 =~ PostLogin|Join[[:space:]]succeeded|RegisterPlayer|OnSessionParticipant.*(join|add)|LobbyMemberStatus.*join|member[[:space:]]joined|HandleStartingNewPlayer ]]
}
# Hosted with players in. Missing or stale data counts as up while the game runs, so callers warn.
session_up() {
  local n status="$CONTROL_DIR/status.json" joined="$RUN_DIR/player-joined"
  jq -e '.hosted == true' "$CONTROL_DIR/readiness.json" >/dev/null 2>&1 || return 1
  n=$(jq -r --arg h "${HOST_NAME:-SN2 Host}" '[.players[]? | select(.name != $h)] | length' "$status" 2>/dev/null) || {
    [ -n "$(game_pid)" ]; return
  }
  [ "${n:-0}" -gt 0 ] && return 0
  [ -f "$joined" ] && [ "$joined" -nt "$status" ] && return 0
  if [ -n "$(game_pid)" ]; then
    local now mtime
    now=$(date +%s); mtime=$(stat -c %Y "$status" 2>/dev/null || echo 0)
    [ $((now - mtime)) -le 45 ] || return 0
  fi
  return 1
}
# MOTD to each name in $2 that is not in $1. Prints the list to remember: $1 again while another
# notice is pending, so the greeting waits instead of overwriting it.
greet_joiners() {
  local prev=$1 cur=$2 joined notice="$CONTROL_DIR/notify-request.json"
  if [ -z "${MOTD:-}" ]; then printf '%s' "$cur"; return 0; fi
  joined=$(comm -13 <(sed '/^$/d' <<<"$prev") <(sed '/^$/d' <<<"$cur"))
  if [ -z "$joined" ]; then printf '%s' "$cur"; return 0; fi
  if [ -e "$notice" ]; then printf '%s' "$prev"; return 0; fi
  jq -cn --arg t "${MOTD:0:200}" --argjson p "$(jq -R . <<<"$joined" | jq -sc .)" \
    '{kind:"info",header:"Welcome",text:$t,duration:10,players:$p}' >"$notice.tmp" && mv "$notice.tmp" "$notice"
  printf '[%s] motd sent to: %s\n' "$(date -u +%FT%TZ)" "$(paste -sd, - <<<"$joined")" >&2
  printf '%s' "$cur"
}
HOST_DISARMED_FILE="$CONTROL_DIR/HOST_DISARMED"
CLIPBOARD_BRIDGE="${CLIPBOARD_BRIDGE:-true}"
UE4SS_CACHE="$DATA_DIR/ue4ss"
UE4SS_LOCAL="$DATA_DIR/ue4ss-local"
PAKS_LOCAL="$DATA_DIR/paks-local"
# Operator layout sets for the pinned loader: one folder per build, with exe.sha256. None ship.
UE4SS_LAYOUTS="${UE4SS_LAYOUTS:-$DATA_DIR/ue4ss-layouts}"
UE4SS_NO_LAYOUT_FILE="$RUN_DIR/ue4ss-no-layout"
# The set whose exe.sha256 is exactly $1; the folder name is only a label.
LAYOUT_FILES="MemberVariableLayout.ini VTableLayout.ini UE4SS-settings.ini"
layout_set_for() {
  local d f
  [ "${#1}" -eq 64 ] || return 1
  for d in "$UE4SS_LAYOUTS"/*/; do
    d=${d%/}
    [ "$(tr -d ' \r\n' <"$d/exe.sha256" 2>/dev/null)" = "$1" ] || continue
    for f in $LAYOUT_FILES; do [ -s "$d/$f" ] || continue 2; done
    echo "$d"
    return 0
  done
  return 1
}
# auto: pinned when an operator's layout set is for this exact build, else upstream-experimental,
# which reads UE 5.6 itself. The install keeps its answer in UE4SS_CHANNEL_FILE.
UE4SS_CHANNEL_FILE="$RUN_DIR/ue4ss-channel"
ue4ss_channel() {
  local c="${UE4SS_CHANNEL:-auto}" h
  [ "$c" = auto ] || { echo "$c"; return 0; }
  c=$(cat "$UE4SS_CHANNEL_FILE" 2>/dev/null)
  case $c in pinned | upstream-experimental) echo "$c"; return 0 ;; esac
  h=$(sha256sum "$WIN64_DIR/$GAME_EXE_NAME" 2>/dev/null | cut -d' ' -f1)
  if [ -n "$h" ] && layout_set_for "$h" >/dev/null; then echo pinned; else echo upstream-experimental; fi
}
GAME_LOG="$LOG_DIR/game.log"
GAME_PIDFILE="$RUN_DIR/game.pid"
# Put in front of the Steam client and the game: they, and any mod the game loads, start without these.
WITHOUT_SECRETS=(env -u DISCORD_WEBHOOK_URL -u CURSEFORGE_API_KEY -u GITHUB_TOKEN -u VNC_PASSWORD -u STEAM_BRANCH_PASSWORD)
STOP_FLAG="$RUN_DIR/stopped"
MOD_SRC="${MOD_SRC:-/opt/sn2/mod}"
# Steam's remembered-login token, kept outside the prefix so a rebuilt one keeps the sign-in.
STEAM_SESSION_DIR="$DATA_DIR/steam-session/local-appdata"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

UE4SS_FAILED_FILE="$RUN_DIR/ue4ss-install-failed"
# What only the loader provides; without it the game still starts and reaches the lobby.
UE4SS_SERVES="automatic hosting (the Host call), the moonpool queue (players, kick, save, slots), status.json and the Discord card, the player cap, and idle freeze"

# An explicit address wins; a quick tunnel's random hostname comes from cloudflared's endpoint.
public_url() {
  local url=${SN2_PUBLIC_URL:-} host=''
  if [ -z "$url" ] && [ "${TUNNEL:-off}" = quick ]; then
    host=$(curl -fsS --max-time 2 "${TUNNEL_METRICS_URL:-http://tunnel:20241/quicktunnel}" 2>/dev/null |
      jq -r '.hostname // empty' 2>/dev/null || true)
    case $host in *.trycloudflare.com) url="https://$host" ;; esac
  fi
  printf '%s' "${url%/}"
}

# Run the loader install; on failure keep its last line in UE4SS_FAILED_FILE. The output goes to
# services.log too, where verify-fresh reads it.
ue4ss_install_step() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ -n "$out" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null
    printf '%s\n' "$out" | tee -a "$LOG_DIR/services.log" 2>/dev/null || printf '%s\n' "$out"
  fi
  if [ "$rc" -eq 0 ]; then rm -f "$UE4SS_FAILED_FILE"; return 0; fi
  mkdir -p "$(dirname "$UE4SS_FAILED_FILE")"
  out=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d; s/^\[[0-9:]*\] //' | tail -n1)
  printf '%s\n' "${out:-exit status $rc, no output}" >"$UE4SS_FAILED_FILE"
  return 1
}

# Why UE4SS must stay out of this launch, or nothing (return 1) when it may load.
ue4ss_hold_reason() {
  local missing
  if [ -s "$UE4SS_FAILED_FILE" ]; then
    printf 'install failed: %s\n' "$(cat "$UE4SS_FAILED_FILE")"; return 0
  fi
  if [ -s "$UE4SS_NO_LAYOUT_FILE" ] && ue4ss_needs_layout_set; then
    printf 'no known-good layout for this build %s (hosting needs one)\n' "$(cat "$UE4SS_NO_LAYOUT_FILE")"; return 0
  fi
  if missing=$(ue4ss_missing "$1"); then return 1; fi
  printf 'missing: %s\n' "$missing"
}

# "loader", or "held <reason>": the game starts without the loader.
ue4ss_launch_mode() {
  local why
  if ! why=$(ue4ss_hold_reason "$1"); then echo loader; return 0; fi
  printf 'held %s\n' "$why"
}

# The stop flag survives a recreate, so it is said once per container start and then hourly.
# $1 flag, $2 state file, $3 container start epoch.
stopped_notice() {
  local flag=$1 st=$2 start=$3 now last
  [ -f "$flag" ] || { rm -f "$st"; return 1; }
  now=$(date +%s); last=$(cat "$st" 2>/dev/null || echo 0)
  case $last in '' | *[!0-9]*) last=0 ;; esac
  [ "$last" -lt "$start" ] && last=0
  [ $((now - last)) -ge 3600 ] || return 0
  echo "$now" >"$st"
  printf 'stopped by moonpool server stop at %s; moonpool server start to run\n' \
    "$(date -u -d "@$(stat -c %Y "$flag")" '+%Y-%m-%d %H:%M UTC')"
}

# Without these in place the game crashed in UE4SS.dll right after "Engine is initialized".
UE4SS_SIGNATURES="FName_Constructor GNatives GUObjectHashTables StaticConstructObject"

# pinned: build 1188 with the operator's layout set; upstream-experimental: build 1190, which
# supports UE 5.6 itself. Prints "<asset> <sha256> <native56>"; UE4SS_ASSET and
# UE4SS_RELEASE_SHA256 override the pin.
ue4ss_channel_select() {
  local asset sha native
  case "${1:-pinned}" in
    pinned)
      asset=UE4SS_v3.0.1-1188-gf885e8d2.zip
      sha=4a594fb5c6e1aa794b06a770730e072c53fb92b741f95a5f0601080d80f4a6c1
      native=no ;;
    upstream-experimental)
      asset=UE4SS_v3.0.1-1190-gf673aac0.zip
      sha=3ce35217fead1982e4563ef974364b7cfedf1dd6d28bb1193caf19877310364b
      native=yes ;;
    *) echo "UE4SS_CHANNEL must be auto, pinned or upstream-experimental, not '$1'" >&2; return 1 ;;
  esac
  printf '%s %s %s\n' "${UE4SS_ASSET:-$asset}" "${UE4SS_RELEASE_SHA256:-$sha}" "$native"
}
ue4ss_needs_layout_set() {
  [ "$(ue4ss_channel_select "$(ue4ss_channel)" | cut -d' ' -f3)" = no ]
}

ue4ss_missing() {
  local w=$1 u="$1/ue4ss" miss="" s
  if ue4ss_needs_layout_set; then
    for s in $UE4SS_SIGNATURES; do [ -s "$u/UE4SS_Signatures/$s.lua" ] || miss="$miss signature:$s"; done
    for s in MemberVariableLayout VTableLayout; do
      [ -s "$u/$s.ini" ] || [ -s "$w/$s.ini" ] || miss="$miss $s.ini"
    done
  fi
  grep -Eq '^MajorVersion *= *5 *$' "$u/UE4SS-settings.ini" 2>/dev/null || miss="$miss MajorVersion=5"
  grep -Eq '^MinorVersion *= *6 *$' "$u/UE4SS-settings.ini" 2>/dev/null || miss="$miss MinorVersion=6"
  [ -s "$w/dwmapi.dll" ] || miss="$miss dwmapi.dll"
  [ -z "$miss" ] && return 0
  printf '%s\n' "${miss# }"; return 1
}

# Seconds to wait before relaunching a game that ran $1 seconds: doubles from 30 to 600, a run of
# 60 s or more resets it. $2 holds the current delay.
crash_backoff() {
  local ran=$1 state=$2 cur
  if [ "$ran" -ge 60 ]; then rm -f "$state"; echo 0; return; fi
  cur=$(cat "$state" 2>/dev/null || echo 0)
  case $cur in '' | *[!0-9]*) cur=0 ;; esac
  if [ "$cur" -eq 0 ]; then cur=30; else cur=$((cur * 2)); fi
  [ "$cur" -gt 600 ] && cur=600
  echo "$cur" >"$state"; echo "$cur"
}

# fetch_pinned URL DEST SHA256: a matching copy at DEST is used; else three download tries.
fetch_pinned() {
  local url=$1 dest=$2 sha=$3 try rc code err actual
  [ -n "$sha" ] || { log "fetch: no pinned SHA-256 for $(basename "$dest"); refusing"; return 1; }
  if [ -f "$dest" ]; then
    actual=$(sha256sum "$dest" | cut -d' ' -f1)
    if [ "$actual" = "$sha" ]; then log "fetch: using local copy $dest (SHA-256 matches)"; return 0; fi
    log "fetch: local copy $dest has SHA-256 $actual, expected $sha; moved to $dest.bad"
    mv -f "$dest" "$dest.bad"
  fi
  for try in 1 2 3; do
    rc=0
    code=$(curl -sSL -o "$dest.part" -w '%{http_code}' "$url" 2>"$dest.err") || rc=$?
    err=$(tr '\n' ' ' <"$dest.err" 2>/dev/null); rm -f "$dest.err"
    if [ "$rc" = 0 ] && [ "${code:-0}" -ge 200 ] && [ "${code:-0}" -lt 300 ]; then
      actual=$(sha256sum "$dest.part" | cut -d' ' -f1)
      if [ "$actual" = "$sha" ]; then mv -f "$dest.part" "$dest"; log "fetch: downloaded $url (try $try)"; return 0; fi
      log "fetch: try $try: downloaded file has SHA-256 $actual, expected $sha"
    else
      log "fetch: try $try: curl exit $rc, HTTP ${code:-none}${err:+: $err}"
    fi
    rm -f "$dest.part"
    [ "$try" = 3 ] || sleep "${SN2_RETRY_PAUSE:-10}"
  done
  log "fetch: gave up on $url; for a container with no outbound access, put the file at $dest"
  return 1
}

game_pid() { pgrep -f "$GAME_EXE_NAME" 2>/dev/null | head -n1; }
# Once shutdown begins, another TERM or INT cannot interrupt the warning and the forced save.
term_stop() {
  trap '' TERM INT
  "${RESTART_WARNING_SCRIPT:-/opt/sn2/bin/restart-warning.sh}" run 'container stopping' || true
  local pid; pid=$(game_pid)
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  exit 0
}
steam_running() { pgrep -fi 'steam\.exe' >/dev/null 2>&1; }

# Log a line only when its text for KEY changes, so a service rerun every second stays quiet.
say_on_change() {
  local key="$1" state="${SN2_STATE_DIR:-/tmp/sn2-state}"
  shift
  mkdir -p "$state"
  [ "$(cat "$state/$key" 2>/dev/null)" = "$*" ] && return 0
  printf '%s' "$*" >"$state/$key"
  if declare -F say >/dev/null; then say "$*"; else log "$*"; fi
}

# vdf_get <file> <key>: one value from a Steam VDF/ACF file, else nothing.
SN2_STEAMFILE="$(dirname "${BASH_SOURCE[0]}")/steamfile.py"
vdf_get() { python3 "$SN2_STEAMFILE" "$1" "$2"; }
# The signed-in account's steamid64; $1 overrides the Steam folder.
host_steamid() {
  python3 "$SN2_STEAMFILE" --account "${1:-$STEAM_DIR}/config/loginusers.vdf" 2>/dev/null || true
}

# Container start as epoch seconds: boot time plus PID 1's start ticks. Not the mtime of /proc/1,
# which procfs re-stamps after a cache drop.
container_start() {
  local stat_file="${SN2_PROC_STAT:-/proc/stat}" pid1="${SN2_PROC_PID1_STAT:-/proc/1/stat}"
  local btime ticks hz
  btime=$(awk '$1 == "btime" { print $2 }' "$stat_file" 2>/dev/null)
  ticks=$(sed 's/.*) //' "$pid1" 2>/dev/null | awk '{ print $20 }')
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  if [[ $btime =~ ^[0-9]+$ && $ticks =~ ^[0-9]+$ && $hz =~ ^[0-9]+$ && $hz -gt 0 ]]; then
    echo $((btime + ticks / hz))
  else
    stat -c %Y /proc/1 2>/dev/null || echo 0
  fi
}

# Installed by Steam's own record: it preallocates the executable when a download starts, and the
# manifest's byte counters stay 0 until the end. Prints absent, requested, installing <size> or
# installed; a game folder with no manifest (a copied install) is installed.
game_install_state() {
  local manifest="${1:-$STEAM_DIR/steamapps/appmanifest_${GAME_APP_ID}.acf}"
  local clog="${2:-$STEAM_DIR/logs/content_log.txt}"
  local exe="${3:-$WIN64_DIR/$GAME_EXE_NAME}"
  local flags last size todl staged tostage
  if [ ! -f "$manifest" ]; then
    if [ -f "$exe" ]; then echo installed; else echo absent; fi
    return 0
  fi
  flags=$(vdf_get "$manifest" StateFlags)
  last=$(grep -E "AppID $GAME_APP_ID (update started|scheduler finished)" "$clog" 2>/dev/null | tail -n1)
  if [ "$flags" = 4 ] && [[ $last != *"update started"* ]]; then echo installed; return 0; fi
  staged=$(vdf_get "$manifest" BytesStaged); tostage=$(vdf_get "$manifest" BytesToStage)
  if [ "${tostage:-0}" -gt 0 ] 2>/dev/null && [ "$staged" = "$tostage" ] && [ -n "$flags" ] \
     && [[ $last != *"update started"* ]]; then
    echo installed; return 0
  fi
  [ -n "$flags" ] || [[ $last == *"update started"* ]] || { echo requested; return 0; }
  todl=$(sed -n 's/.*update started : download [0-9]*\/\([0-9]*\).*/\1/p' <<<"$last")
  [ -n "$todl" ] || todl=$(vdf_get "$manifest" BytesToDownload)
  if [ "${todl:-0}" -gt 0 ] 2>/dev/null; then
    size=$(awk -v b="$todl" 'BEGIN { printf "%.1f GB", b / 1e9 }')
  else
    size="(size not known yet)"
  fi
  echo "installing $size"
}

download_rate() {
  grep -o 'Current download rate: .*' "${1:-$STEAM_DIR/logs/content_log.txt}" 2>/dev/null | tail -n1
}

# One line per install state change, plus Steam's download rate at most once a minute.
install_progress() {
  local state="$1" clog="${2:-$STEAM_DIR/logs/content_log.txt}"
  local stamp="${SN2_STATE_DIR:-/tmp/sn2-state}/rate-logged" rate
  say_on_change install "$state"
  rate=$(download_rate "$clog")
  [ -n "$rate" ] || return 0
  if [ ! -f "$stamp" ] || [ $(($(date +%s) - $(stat -c %Y "$stamp"))) -ge 60 ]; then
    : >"$stamp"
    if declare -F say >/dev/null; then say "download: $rate"; else log "download: $rate"; fi
  fi
}

# VNC_PASSWORD, else one made at first start (mode 600). websockify listens on every interface
# inside the container, so the viewer always has a password.
viewer_password() {
  local file="${VIEWER_PASSWORD_FILE:-$DATA_DIR/viewer-password}"
  if [ -n "${VNC_PASSWORD:-}" ]; then printf '%s' "$VNC_PASSWORD"; return 0; fi
  if [ ! -s "$file" ]; then
    (umask 077; openssl rand -base64 12 | tr -d '\n' >"$file") || return 1
  fi
  chmod 600 "$file" 2>/dev/null
  cat "$file"
}

# The Steam installer is run only with Valve's Authenticode signature on it, checked
# against the system's roots. STEAM_SETUP_UNVERIFIED=true skips the check, said in the log.
steam_setup_signed() {
  local file=$1 out
  if [ "${STEAM_SETUP_UNVERIFIED:-}" = true ]; then log "SteamSetup.exe signature check skipped (STEAM_SETUP_UNVERIFIED=true)"; return 0; fi
  command -v osslsigncode >/dev/null || { log "osslsigncode missing: cannot check SteamSetup.exe"; return 1; }
  out=$(osslsigncode verify -in "$file" -CAfile "${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" 2>&1) || { log "SteamSetup.exe signature did not verify"; return 1; }
  printf '%s' "$out" | grep -q 'Subject: .*O=Valve Corp\.' || { log "SteamSetup.exe is signed, but not by Valve Corp."; return 1; }
  return 0
}

# Signed in = a remembered account and one of: MostRecent "1" (older clients), a LogOnResponse
# 'OK' since this container started, or the token file while a logged-on client runs.
# Sets STEAM_SIGNIN_SIGNAL to the evidence that decided it.
steam_signed_in() {
  local vdf="${1:-$STEAM_DIR/config/loginusers.vdf}" logs="${2:-$STEAM_DIR/logs}"
  local token="${3:-$STEAM_SESSION_DIR/local.vdf}" since="${4:-$(container_start)}"
  STEAM_SIGNIN_SIGNAL=""
  [ -f "$vdf" ] || { STEAM_SIGNIN_SIGNAL="no loginusers.vdf"; return 1; }
  if ! grep -Eq '"(AutoLogin|RememberPassword)"[[:space:]]+"1"' "$vdf"; then
    STEAM_SIGNIN_SIGNAL="no remembered account"; return 1
  fi
  # The newest connection result wins: Steam can log off later ("Logged In Elsewhere").
  local newest
  newest=$(cat "$logs"/connection_log*.txt 2>/dev/null \
    | grep -E "RecvMsgClient(LogOnResponse|LoggedOff)" | LC_ALL=C sort | tail -n1)
  if [[ $newest == *"RecvMsgClientLoggedOff"* ]]; then
    STEAM_SIGNIN_SIGNAL="logged off: ${newest##*RecvMsgClientLoggedOff}"
    return 1
  fi
  if grep -Eq '"MostRecent"[[:space:]]+"1"' "$vdf"; then
    STEAM_SIGNIN_SIGNAL="MostRecent in loginusers.vdf"; return 0
  fi
  local floor last state
  floor=$(date -u -d "@$since" '+%Y-%m-%d %H:%M:%S')
  last=$(cat "$logs"/connection_log*.txt "$logs"/console_log*.txt 2>/dev/null \
    | grep -E "RecvMsgClientLogOnResponse\(\) : .*'OK'" \
    | sed -n 's/^\[\([0-9-]* [0-9:]*\)\].*/\1/p' | sort | tail -n1)
  if [ -n "$last" ] && [[ ! "$last" < "$floor" ]]; then
    STEAM_SIGNIN_SIGNAL="LogOnResponse 'OK' at $last"; return 0
  fi
  # The log outlives its client: a previous container's "Logged On" does not count.
  local line stamp
  line=$(cat "$logs"/connection_log*.txt 2>/dev/null \
    | sed -n 's/^\[\([0-9-]* [0-9:]*\)\] \[\([A-Za-z ]*\),.*/\1|\2/p' | tail -n1)
  stamp=${line%%|*}; state=${line#*|}
  if [ -n "$stamp" ] && [[ "$stamp" < "$floor" ]]; then state="stale: $state"; fi
  if [ -s "$token" ] && [ "$state" = "Logged On" ] && steam_running; then
    STEAM_SIGNIN_SIGNAL="token file and a logged-on client"; return 0
  fi
  STEAM_SIGNIN_SIGNAL="remembered account, but no logon seen since container start"
  return 1
}

restart_steam_client() {
  if [ -d /run/service/sn2-steam ]; then
    s6-svc -r /run/service/sn2-steam
  else
    pkill -f '[sS]team\.exe' 2>/dev/null || true
  fi
}

restart_steam_after_logoff() {
  local signal=$1 marker=$2
  [ "$(cat "$marker" 2>/dev/null)" != "$signal" ] || return 1
  printf '%s\n' "$signal" >"$marker"
  if declare -F say >/dev/null; then
    say_on_change steam-logged-off "Steam client ${signal}; restarting sn2-steam"
  fi
  restart_steam_client
}

# Keep the logs the game and UE4SS overwrite on their next start, one folder per launch.
archive_previous_logs() {
  local root="${1:-$DATA_DIR/log-history}" game_log="$2" mod_log="$3" stamp="$4" dir
  [ -f "$game_log" ] || [ -f "$mod_log" ] || return 0
  dir="$root/$stamp"
  mkdir -p "$dir"
  [ ! -f "$game_log" ] || cp -p "$game_log" "$dir/game.log"
  [ ! -f "$mod_log" ] || cp -p "$mod_log" "$dir/UE4SS.log"
  find "$root" -mindepth 1 -maxdepth 1 -type d -print | sort -r | tail -n +31 \
    | while IFS= read -r old; do
        case $old in "$root"/*) rm -rf -- "${old:?}" ;; esac
      done
  log "archived previous game logs in $dir"
}

# Pak mods the host runs: the .pak/.ucas/.utoc files in $PAKS_LOCAL are copied into the game's
# Content/Paks/~mods before each launch. Each copy is recorded with its sha256, and one whose source
# is gone is removed only while it still has those bytes: nothing else in ~mods is touched. Names are
# plain file names, and a link on either side is never followed.
pak_name_ok() { case "$1" in */* | .* | "") return 1 ;; esac; printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_ .()+-]*\.(pak|ucas|utoc)$'; }
apply_local_paks() {
  local mods="$GAME_DIR/Subnautica2/Content/Paks/~mods" list="$RUN_DIR/paks-local.list" f n sum
  if [ -f "$list" ]; then
    while read -r sum n; do
      pak_name_ok "$n" || continue
      [ -f "$PAKS_LOCAL/$n" ] && continue
      { [ -f "$mods/$n" ] && [ ! -L "$mods/$n" ]; } || continue
      [ "$(sha256sum "$mods/$n" | cut -d' ' -f1)" = "$sum" ] && rm -f "$mods/$n"
    done <"$list"
  fi
  : >"$list.tmp"
  for f in "$PAKS_LOCAL"/*.pak "$PAKS_LOCAL"/*.ucas "$PAKS_LOCAL"/*.utoc; do
    { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
    n=${f##*/}
    pak_name_ok "$n" || { log "host pak mods: skipped $n (not a plain .pak/.ucas/.utoc name)"; continue; }
    mkdir -p "$mods"
    if [ -L "$mods/$n" ] || { [ -e "$mods/$n" ] && [ ! -f "$mods/$n" ]; }; then
      log "host pak mods: skipped $n (a link or folder is in its place in ~mods)"; continue
    fi
    if ! cmp -s "$f" "$mods/$n"; then
      cp -f "$f" "$mods/.$n.tmp" && mv -f "$mods/.$n.tmp" "$mods/$n"
    fi
    printf '%s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$n" >>"$list.tmp"
  done
  mv -f "$list.tmp" "$list"
  if [ -s "$list" ]; then log "host pak mods from $PAKS_LOCAL: $(cut -d' ' -f2- "$list" | tr '\n' ' ')"; fi
}

# Create the volume layout; the control directory is private to this user.
ensure_layout() {
  mkdir -p "$LOG_DIR" "$RUN_DIR" "$UE4SS_CACHE" "$UE4SS_LOCAL" "$PAKS_LOCAL" "$STAGING_DIR" \
    "$CONTROL_DIR/inbox" "$CONTROL_DIR/outbox" "$CONTROL_DIR/tmp" "$CONTROL_DIR/receipts"
  # Run as root, the folder goes to the game's user or the mod cannot read it.
  if [ "$(id -u)" = 0 ] && [ -n "${GAME_USER:-}" ] && id "$GAME_USER" >/dev/null 2>&1; then
    chown -R "$GAME_USER:" "$CONTROL_DIR"
  fi
  chmod 0700 "$CONTROL_DIR"
  local mode
  mode=$(stat -c '%a' "$CONTROL_DIR")
  if [ "$mode" != "700" ]; then
    log "control directory $CONTROL_DIR has mode $mode and cannot be made private; refusing"
    return 1
  fi
}

winpath() { printf 'Z:%s' "${1//\//\\}"; }
