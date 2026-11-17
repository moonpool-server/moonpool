#!/usr/bin/env bats
# save-stage.sh copies the saves into backup-staging/<UTC second>/. The join watcher, the autosave
# hook and moonpool can start it at the same moment, so two stagings may share a second.
# shellcheck disable=SC2030,SC2031 # Each @test has its own Bats subshell.

setup() {
  S="$BATS_TEST_DIRNAME/../scripts/save-stage.sh"
  export DATA_DIR="$BATS_TEST_TMPDIR/data" SAVE_DIR="$BATS_TEST_TMPDIR/saves"
  STAGE="$DATA_DIR/backup-staging"
  mkdir -p "$DATA_DIR/logs" "$SAVE_DIR"
  echo GSWU-one >"$SAVE_DIR/Slot1.sav"
  # date answers the staging name with the same second twice, then the next second.
  local stubs="$BATS_TEST_TMPDIR/stubs" real
  real=$(command -v date)
  mkdir -p "$stubs"
  cat >"$stubs/date" <<EOF
#!/bin/sh
if [ "\$*" = '-u +%Y%m%dT%H%M%SZ' ]; then
  n=\$(cat "$BATS_TEST_TMPDIR/date.count" 2>/dev/null || echo 0); echo \$((n + 1)) >"$BATS_TEST_TMPDIR/date.count"
  if [ "\$n" -lt 2 ]; then echo 20260101T000000Z; else echo 20260101T000001Z; fi
  exit 0
fi
exec "$real" "\$@"
EOF
  chmod +x "$stubs/date"
  export PATH="$stubs:$PATH"
}

# Each staged folder holds exactly the one save, with nothing nested under SaveGames.
two_whole_stagings() {
  [ "$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
  for d in "$STAGE"/20260101T000000Z "$STAGE"/20260101T000001Z; do
    [ "$(cat "$d/SaveGames/Slot1.sav")" = GSWU-one ]
    [ "$(find "$d/SaveGames" -mindepth 1 | wc -l)" -eq 1 ]
  done
}

@test "two stagings in the same second land in two whole folders, neither nested" {
  run "$S" --now; [ "$status" -eq 0 ]
  run "$S" --now; [ "$status" -eq 0 ]
  two_whole_stagings
}

@test "stagings started together take turns, and both finish" {
  # A slow copy keeps the first staging busy while the second starts.
  local real; real=$(command -v cp)
  printf '#!/bin/sh\nsleep 1\nexec %s "$@"\n' "$real" >"$BATS_TEST_TMPDIR/stubs/cp"
  chmod +x "$BATS_TEST_TMPDIR/stubs/cp"
  ("$S" --now; echo $? >"$BATS_TEST_TMPDIR/a.rc") &
  ("$S" --now; echo $? >"$BATS_TEST_TMPDIR/b.rc") &
  wait
  [ "$(cat "$BATS_TEST_TMPDIR/a.rc")" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/b.rc")" -eq 0 ]
  two_whole_stagings
  [ -z "$(find "$STAGE" -name '.stage.*' -type d)" ]
}

@test "a fresh install with no save folder yet is not a failure; a lost one after earlier copies is" {
  rm -rf "$SAVE_DIR"
  run "$S" --now
  [ "$status" -eq 0 ]
  grep -q 'nothing to stage: no world saved yet' "$DATA_DIR/logs/backup.log"
  mkdir -p "$STAGE/20260101T000000Z"
  run "$S" --now
  [ "$status" -eq 1 ]
  grep -q 'FAILED: save folder missing' "$DATA_DIR/logs/backup.log"
}
