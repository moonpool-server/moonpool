#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Each @test has its own Bats subshell.
bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  SOURCE="$BATS_TEST_TMPDIR/source"
  ARCHIVE="$BATS_TEST_TMPDIR/archive"
  mkdir -p "$SOURCE" "$ARCHIVE"
  printf 'world one\n' >"$SOURCE/Slot1.sav"
  STUB="$BATS_TEST_TMPDIR/offen-stub"
  cat >"$STUB" <<'EOF'
#!/bin/sh
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$STUB_COUNT"
printf "%${STUB_SIZE:-1024}s" x >"$BACKUP_ARCHIVE/sn2-saves-2026-11-03T12-00-0$n.tar.gz"
EOF
  chmod +x "$STUB"
  export BACKUP_SOURCES="$SOURCE" BACKUP_ARCHIVE="$ARCHIVE"
  export STUB_COUNT="$BATS_TEST_TMPDIR/count" SN2_BACKUP_COMMAND="$STUB"
}

run_backup() { run sh "$ROOT/scripts/backup-run.sh" --run; }

@test "unchanged staged saves create only one archive by default" {
  run_backup; [ "$status" -eq 0 ]; [ "$(cat "$STUB_COUNT")" -eq 1 ]
  run_backup; [ "$status" -eq 0 ]; [ "$(cat "$STUB_COUNT")" -eq 1 ]
  [[ "$output" == *"unchanged; no archive created"* ]]
}

@test "a changed staged save creates another archive" {
  run_backup; [ "$status" -eq 0 ]
  printf 'new autosave\n' >>"$SOURCE/Slot1.sav"
  run_backup; [ "$status" -eq 0 ]; [ "$(cat "$STUB_COUNT")" -eq 2 ]
}

@test "unchanged saves are archived again after their archive disappears" {
  run_backup; [ "$status" -eq 0 ]
  rm "$ARCHIVE/sn2-saves-2026-11-03T12-00-01.tar.gz"
  run_backup; [ "$status" -eq 0 ]; [ "$(cat "$STUB_COUNT")" -eq 2 ]
}

@test "failed offen run does not mark content as backed up" {
  SN2_BACKUP_COMMAND=false run_backup; [ "$status" -ne 0 ]
  run_backup; [ "$status" -eq 0 ]; [ "$(cat "$STUB_COUNT")" -eq 1 ]
}

@test "size cap removes oldest local archives after a run" {
  printf '%2097152s' x >"$ARCHIVE/sn2-saves-2026-11-03T11-00-00.tar.gz"
  export BACKUP_MAX_TOTAL_MB=2 BACKUP_SKIP_UNCHANGED=false
  run_backup; [ "$status" -eq 0 ]
  [ ! -e "$ARCHIVE/sn2-saves-2026-11-03T11-00-00.tar.gz" ]
  [ -e "$ARCHIVE/sn2-saves-2026-11-03T12-00-01.tar.gz" ]
}

@test "size cap keeps the newest archive when one archive exceeds it" {
  export BACKUP_MAX_TOTAL_MB=1 BACKUP_SKIP_UNCHANGED=false STUB_SIZE=2097152
  run_backup; [ "$status" -eq 0 ]
  [ -e "$ARCHIVE/sn2-saves-2026-11-03T12-00-01.tar.gz" ]
  [ "$(grep -c 'newest archive exceeds' <<<"$output")" -eq 1 ]
}

@test "zero size cap is disabled" {
  export BACKUP_MAX_TOTAL_MB=0 BACKUP_SKIP_UNCHANGED=false
  printf old >"$ARCHIVE/sn2-saves-2026-11-03T11-00-00.tar.gz"
  run_backup; [ "$status" -eq 0 ]
  [ -e "$ARCHIVE/sn2-saves-2026-11-03T11-00-00.tar.gz" ]
  [ -e "$ARCHIVE/sn2-saves-2026-11-03T12-00-01.tar.gz" ]
}

@test "size cap ignores partial and similarly prefixed files" {
  export BACKUP_MAX_TOTAL_MB=1 BACKUP_SKIP_UNCHANGED=false
  printf '%2097152s' x >"$ARCHIVE/sn2-saves-2026-11-03T10-00-00.tar.gz.partial"
  printf '%2097152s' x >"$ARCHIVE/sn2-saves-not-an-archive"
  run_backup; [ "$status" -eq 0 ]
  [ -e "$ARCHIVE/sn2-saves-2026-11-03T10-00-00.tar.gz.partial" ]
  [ -e "$ARCHIVE/sn2-saves-not-an-archive" ]
}

@test "empty size cap leaves local archives alone" {
  printf old >"$ARCHIVE/sn2-saves-2026-11-03T11-00-00.tar.gz"
  run_backup; [ "$status" -eq 0 ]
  [ -e "$ARCHIVE/sn2-saves-2026-11-03T11-00-00.tar.gz" ]
}

@test "compose accepts an absent optional backup.env" {
  command -v docker >/dev/null || skip "docker is unavailable"
  [ ! -e "$ROOT/backup.env" ] || skip "developer has a backup.env"
  run docker compose -f "$ROOT/compose.yaml" config --quiet
  [ "$status" -eq 0 ]
}

@test "compose loads backup.env when it is present" {
  command -v docker >/dev/null || skip "docker is unavailable"
  [ ! -e "$ROOT/backup.env" ] || skip "developer has a backup.env"
  printf 'WEBDAV_URL=https://backup.invalid/dav\n' >"$ROOT/backup.env"
  run docker compose -f "$ROOT/compose.yaml" config
  rm -f "$ROOT/backup.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WEBDAV_URL: https://backup.invalid/dav"* ]]
}
