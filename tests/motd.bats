#!/usr/bin/env bats
# The join greeting (MOTD): who gets it, and that a pending notice is never overwritten.
setup() {
  export DATA_DIR="$BATS_TEST_TMPDIR/data" SN2_CONTROL_DIR="$BATS_TEST_TMPDIR/data/control"
  mkdir -p "$SN2_CONTROL_DIR"
  . scripts/common.sh
  NOTICE="$SN2_CONTROL_DIR/notify-request.json"
}

@test "only the player new since the last read is greeted" {
  MOTD='Welcome aboard'
  run greet_joiners $'Diver' $'Diver\nPilot'
  [ "$status" -eq 0 ]
  [[ "$output" == *"motd sent to: Pilot"* ]]
  [ "$(jq -c .players "$NOTICE")" = '["Pilot"]' ]
  [ "$(jq -r .text "$NOTICE")" = 'Welcome aboard' ]
}

@test "nobody new means no notice" {
  MOTD='Welcome aboard'
  run greet_joiners $'Diver\nPilot' $'Diver'
  [ "$status" -eq 0 ]; [ ! -e "$NOTICE" ]
  [ "$output" = Diver ]
}

@test "a pending notice keeps the old list so the greeting goes out next read" {
  MOTD='Welcome aboard'
  echo '{"kind":"warning","text":"restart"}' >"$NOTICE"
  run greet_joiners $'Diver' $'Diver\nPilot'
  [ "$output" = Diver ]
  [ "$(jq -r .text "$NOTICE")" = restart ]
}

@test "an empty MOTD sends nothing and remembers the current list" {
  MOTD=''
  run greet_joiners '' $'Pilot'
  [ "$output" = Pilot ]; [ ! -e "$NOTICE" ]
}

@test "the greeting is cut at 200 characters" {
  MOTD=$(printf 'x%.0s' $(seq 1 300))
  run greet_joiners '' $'Pilot'
  [ "$(jq -r '.text | length' "$NOTICE")" -eq 200 ]
}
