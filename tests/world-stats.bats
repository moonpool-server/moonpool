#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  DATA="$BATS_TEST_TMPDIR/data"
  SAVE="$BATS_TEST_TMPDIR/saves"
  STAGE="$DATA/backup-staging"
  ARCHIVE="$BATS_TEST_TMPDIR/archive"
  mkdir -p "$DATA/logs" "$DATA/control" "$SAVE" "$STAGE/old/SaveGames" "$ARCHIVE"
  export DATA_DIR="$DATA" WORLD_STATS_SAVE_DIR="$SAVE" WORLD_STATS_STAGING_DIR="$STAGE"
  export WORLD_STATS_ARCHIVE_DIR="$ARCHIVE" WORLD_STATS_CACHE="$DATA/world-stats.json"
  export SN2_NOW=1800000000
}

stats() { run python3 "$ROOT/scripts/world-stats.py"; }

@test "world history combines saves, metrics, joins, and status" {
  printf save >"$SAVE/Slot1.sav"
  printf old >"$STAGE/old/SaveGames/Slot1.sav"
  touch -t 202611011200.00 "$SAVE/Slot1.sav"
  touch -t 202610011030.00 "$STAGE/old/SaveGames/Slot1.sav"
  cat >"$DATA/metrics.csv" <<'EOF'
utc,cpu_cores,mem_mib,players
2026-11-01T10:00:00Z,1,100,2
2026-11-01T10:01:00Z,1,100,1
2026-11-01T10:02:00Z,1,100,0
2026-11-01T11:00:00Z,1,100,3
EOF
  cat >"$DATA/logs/join_watch.log" <<'EOF'
[x] Join succeeded: Zoe
[x] Join succeeded: Amy
[x] Join succeeded: Zoe
EOF
  echo '{"day":17}' >"$DATA/control/status.json"
  stats
  [ "$status" -eq 0 ]
  [ "$(jq -r .created <<<"$output")" = '2026-10-01T10:30:00Z' ]
  [ "$(jq -r .created_source <<<"$output")" = 'backup-staging' ]
  [ "$(jq -r .hours_played <<<"$output")" = '0.05' ]
  [ "$(jq -r .sessions <<<"$output")" = 2 ]
  [ "$(jq -r .peak_players <<<"$output")" = 3 ]
  [ "$(jq -r .last_played <<<"$output")" = '2026-11-01T11:01:00Z' ]
  [ "$(jq -c .players_seen <<<"$output")" = '["Amy","Zoe"]' ]
  [ "$(jq -r .in_game_day <<<"$output")" = 17 ]
}

@test "archive names supply creation and hidden names become a count" {
  touch "$ARCHIVE/sn2-saves-2025-02-03T04-05-06.tar.gz"
  printf '%s\n' 'Join succeeded: Amy' 'Join succeeded: Zoe' >"$DATA/logs/join_watch.log"
  SHOW_PLAYER_NAMES=false stats
  [ "$status" -eq 0 ]
  [ "$(jq -r .created <<<"$output")" = '2025-02-03T04:05:06Z' ]
  [ "$(jq -r .created_source <<<"$output")" = 'backup archive name' ]
  [ "$(jq -r .players_seen <<<"$output")" = 2 ]
  [ "$(jq -r .hours_played <<<"$output")" = null ]
}

@test "missing sources stay null and a fresh cache is reused" {
  stats; [ "$status" -eq 0 ]
  [ "$(jq -r '[.[]] | all(. == null)' <<<"$output")" = true ]
  echo '{"cached":true}' >"$WORLD_STATS_CACHE"
  touch -t 202701150800.00 "$WORLD_STATS_CACHE"
  stats; [ "$status" -eq 0 ]
  [ "$output" = '{"cached":true}' ]
}
