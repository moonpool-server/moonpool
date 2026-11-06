#!/usr/bin/env bash
# The save, watcher, metrics, backup, and mod files are
# local SN2 host formats; no existing tool joins them into one privacy-aware summary.
# Print durable facts about the served world as one JSON object. Results are cached
# for ten minutes because metrics.csv is append-only and may become large.
set -euo pipefail

DATA_DIR=${DATA_DIR:-/data}
SAVE_DIR=${WORLD_STATS_SAVE_DIR:-${GAME_DIR:-/home/container/game}/Subnautica2/Saved/SaveGames}
STAGING_DIR=${WORLD_STATS_STAGING_DIR:-$DATA_DIR/backup-staging}
ARCHIVE_DIR=${WORLD_STATS_ARCHIVE_DIR:-/archive}
METRICS=${WORLD_STATS_METRICS:-$DATA_DIR/metrics.csv}
JOIN_LOG=${WORLD_STATS_JOIN_LOG:-$DATA_DIR/logs/join_watch.log}
STATUS_JSON=${WORLD_STATS_STATUS_JSON:-$DATA_DIR/control/status.json}
CACHE=${WORLD_STATS_CACHE:-$DATA_DIR/world-stats.json}
NOW=${SN2_NOW:-$(date +%s)}

if [ -s "$CACHE" ]; then
  cache_time=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  if [ $((NOW - cache_time)) -lt 600 ] && jq -e . "$CACHE" >/dev/null 2>&1; then
    cat "$CACHE"
    exit 0
  fi
fi

created_epoch=''
created_source=''
consider_file() {
  [ -f "$1" ] || return 0
  local epoch
  epoch=$(stat -c %Y "$1" 2>/dev/null || true)
  case $epoch in ''|*[!0-9]*) return 0 ;; esac
  if [ -z "$created_epoch" ] || [ "$epoch" -lt "$created_epoch" ]; then
    created_epoch=$epoch
    created_source=$2
  fi
}

# Live saves and their .bak siblings carry the oldest filesystem history still
# present. Staged copies preserve those mtimes (`cp -a`).
if [ -d "$SAVE_DIR" ]; then
  while IFS= read -r path; do consider_file "$path" 'SaveGames'; done < <(find "$SAVE_DIR" -type f 2>/dev/null)
fi
if [ -d "$STAGING_DIR" ]; then
  while IFS= read -r path; do consider_file "$path" 'backup-staging'; done < <(find "$STAGING_DIR" -type f 2>/dev/null)
fi

# Offen archive names contain their creation instant. The name is usable even
# when archive contents are unavailable to the game container.
if [ -d "$ARCHIVE_DIR" ]; then
  while IFS= read -r path; do
    name=${path##*/}
    stamp=${name#sn2-saves-}; stamp=${stamp%.tar.gz}
    case $stamp in
      ????-??-??T??-??-??)
        epoch=$(date -u -d "${stamp:0:10} ${stamp:11:2}:${stamp:14:2}:${stamp:17:2}" +%s 2>/dev/null || true)
        if [ -n "$epoch" ] && { [ -z "$created_epoch" ] || [ "$epoch" -lt "$created_epoch" ]; }; then
          created_epoch=$epoch; created_source='backup archive name'
        fi
        ;;
    esac
  done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name 'sn2-saves-*.tar.gz' 2>/dev/null)
fi

created=null
if [ -n "$created_epoch" ]; then created=$(date -u -d "@$created_epoch" +%FT%TZ | jq -R .); fi
source_json=null
if [ -n "$created_source" ]; then source_json=$(printf '%s' "$created_source" | jq -R .); fi

metrics='{"hours_played":null,"sessions":null,"peak_players":null,"peak_when":null,"last_played":null}'
if [ -s "$METRICS" ]; then
  metrics=$(awk -F, '
    function leap(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
    function minute(t, y,m,d,h,n,i,total,mdays) {
      if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]/) return ""
      y=substr(t,1,4)+0; m=substr(t,6,2)+0; d=substr(t,9,2)+0
      h=substr(t,12,2)+0; n=substr(t,15,2)+0
      total=365*(y-1970)+int((y-1969)/4)-int((y-1901)/100)+int((y-1901)/400)
      split("31 28 31 30 31 30 31 31 30 31 30 31", mdays, " "); if (leap(y)) mdays[2]=29
      for (i=1; i<m; i++) total+=mdays[i]
      return (total+d-1)*1440+h*60+n
    }
    NR == 1 {
      for (i=1; i<=NF; i++) if ($i == "players") p=i
      if (!p) p=4
      next
    }
    p && $p ~ /^[0-9]+$/ {
      seen=1; count=$p+0
      if (count > peak) { peak=count; peak_at=$1 }
      if (count > 0) {
        positive++
        current=minute($1)
        if (!in_session || current == "" || previous == "" || current-previous > 1) sessions++
        in_session=1; last=$1; previous=current
      } else { in_session=0; previous="" }
    }
    END {
      if (!seen) { print "{\"hours_played\":null,\"sessions\":null,\"peak_players\":null,\"peak_when\":null,\"last_played\":null}"; exit }
      printf "{\"hours_played\":%.2f,\"sessions\":%d,\"peak_players\":%d,", positive/60, sessions, peak
      if (peak_at != "") printf "\"peak_when\":\"%s\",", peak_at; else printf "\"peak_when\":null,"
      if (last != "") printf "\"last_played\":\"%s\"}", last; else printf "\"last_played\":null}"
    }
  ' "$METRICS")
  # Each occupied sample represents that minute; report the end of the final one.
  metrics=$(jq -c 'if .last_played then .last_played = ((.last_played | fromdateiso8601) + 60 | strftime("%Y-%m-%dT%H:%M:%SZ")) else . end' <<<"$metrics")
fi

players_seen=null
if [ -f "$JOIN_LOG" ]; then
  names=$(sed -nE 's/.*Join succeeded: (.*)$/\1/p' "$JOIN_LOG" | sort -u)
  if [ "${SHOW_PLAYER_NAMES:-true}" = false ]; then
    players_seen=$(printf '%s\n' "$names" | awk 'NF { n++ } END { print n+0 }')
  else
    players_seen=$(printf '%s\n' "$names" | jq -Rsc 'split("\n") | map(select(length > 0))')
  fi
fi

in_game_day=null
if [ -s "$STATUS_JSON" ]; then in_game_day=$(jq -c 'if (.day | type) == "number" then .day else null end' "$STATUS_JSON" 2>/dev/null || echo null); fi

mkdir -p "$(dirname "$CACHE")"
tmp="$CACHE.tmp.$$"
jq -cn \
  --argjson created "$created" --argjson created_source "$source_json" \
  --argjson metrics "$metrics" --argjson players_seen "$players_seen" --argjson in_game_day "$in_game_day" \
  '{created:$created,created_source:$created_source,hours_played:$metrics.hours_played,
    sessions:$metrics.sessions,players_seen:$players_seen,peak_players:$metrics.peak_players,
    peak_when:$metrics.peak_when,last_played:$metrics.last_played,in_game_day:$in_game_day}' >"$tmp"
mv "$tmp" "$CACHE"
cat "$CACHE"
