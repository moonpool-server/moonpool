#!/usr/bin/env bats
# The two guards that stand between a default setting and something hard to undo: no game update
# without a save copy, and no viewer off this machine without a password. Both scripts name
# /opt/sn2/bin by absolute path, so each runs as a copy with that path pointed at a temp folder.
# shellcheck disable=SC2030,SC2031

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  BIN="$BATS_TEST_TMPDIR/bin"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BIN" "$STUBS"
  cp "$ROOT/scripts/common.sh" "$BIN/"
  for s in scripts/install-game.sh docker/sn2-service.sh; do
    sed "s#/opt/sn2/bin#$BIN#g" "$ROOT/$s" >"$BIN/${s##*/}"
  done
  export DATA_DIR="$BATS_TEST_TMPDIR/data" GAME_DIR="$BATS_TEST_TMPDIR/game" STEAM_BRANCH=public
  export SN2_BIN="$BIN" SAVE_DIR="$BATS_TEST_TMPDIR/saves" SN2_STATE_DIR="$BATS_TEST_TMPDIR/state" AUTO_UPDATE=true
  export PATH="$STUBS:$PATH"
  unset UPDATE_WITHOUT_BACKUP VIEWER_BIND VNC_PASSWORD
  mkdir -p "$DATA_DIR/logs" "$GAME_DIR/Subnautica2/Binaries/Win64"
  : >"$GAME_DIR/Subnautica2/Binaries/Win64/Subnautica2-Win64-Shipping.exe"
  stub pgrep 'exit 0'
  stub wine "printf '%s\n' \"\$*\" >>'$CALLS.wine'"
  stub websockify "printf '%s\n' \"\$*\" >>'$CALLS.websockify'"
  stub sleep "printf '%s\n' \"\$*\" >>'$CALLS.sleep'"
  printf '#!/bin/sh\nexit 1\n' >"$BIN/save-stage.sh"
  chmod +x "$BIN/save-stage.sh"
}

stub() { printf '#!/bin/sh\n%s\n' "$2" >"$STUBS/$1"; chmod +x "$STUBS/$1"; }

# install-game.sh starts wine in the background: give it time to arrive.
steam_validated() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -qs 'steam://validate/' "$CALLS.wine" && return 0
    /bin/sleep 0.1
  done
  return 1
}

@test "a failed save copy of an existing save folder stops the update and says why" {
  mkdir -p "$SAVE_DIR"
  run bash "$BIN/install-game.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"no save copy, so no update"* ]]
  [[ $output != *"Steam validates"* ]]
  /bin/sleep 0.3
  [ ! -e "$CALLS.wine" ]
}

@test "UPDATE_WITHOUT_BACKUP=true updates despite the failed save copy" {
  mkdir -p "$SAVE_DIR"
  UPDATE_WITHOUT_BACKUP=true run bash "$BIN/install-game.sh"
  [ "$status" -eq 0 ]
  steam_validated
}

@test "a new world has nothing to copy, so it updates" {
  run bash "$BIN/install-game.sh"
  [ "$status" -eq 0 ]
  steam_validated
}

viewer() { run env "$@" bash "$BIN/sn2-service.sh" novnc; }

signed() { run bash -c ". '$BIN/common.sh'; steam_setup_signed /tmp/SteamSetup.exe && echo signed || echo refused"; }

@test "the Steam installer runs only with Valve's signature verified" {
  stub osslsigncode 'printf "Signer #0:\n\t\tSubject: /C=US/O=Valve Corp./CN=Valve Corp.\nSucceeded\n"; exit 0'
  signed; [[ "$output" == *signed ]]
  stub osslsigncode 'printf "Signer #0:\n\t\tSubject: /C=US/O=Someone Else/CN=Someone Else\nSucceeded\n"; exit 0'
  signed; [[ "$output" == *refused ]]
  stub osslsigncode 'printf "Failed\n"; exit 1'
  signed; [[ "$output" == *refused ]]
  STEAM_SETUP_UNVERIFIED=true signed; [[ "$output" == *signed ]]
}
@test "a viewer open to the LAN starts with no password set, because one is always made" {
  viewer VIEWER_BIND=0.0.0.0 VNC_PASSWORD= VIEWER_PASSWORD_FILE="$BATS_TEST_TMPDIR/viewer-password"
  [ -s "$CALLS.websockify" ] && [ ! -e "$CALLS.sleep" ]
}

@test "a viewer open to the LAN with a password starts" {
  viewer VIEWER_BIND=0.0.0.0 VNC_PASSWORD=hunter2
  [ -s "$CALLS.websockify" ]
}

@test "a viewer on this machine alone starts the same way" {
  viewer VIEWER_BIND=127.0.0.1 VNC_PASSWORD=
  [ -s "$CALLS.websockify" ]
}

@test "steam waits for a save copy, because steam itself can update the game" {
  mkdir -p "$SAVE_DIR" "$DATA_DIR/run"
  # shellcheck disable=SC2016
  check() { env "$@" bash -c '. "$1/common.sh"; save_copy_before_update' _ "$BIN"; }
  run check X=1
  [ "$status" -ne 0 ]
  run check UPDATE_WITHOUT_BACKUP=true
  [ "$status" -eq 0 ]
  run check AUTO_UPDATE=false
  [ "$status" -eq 0 ]
  rmdir "$SAVE_DIR"
  run check X=1
  [ "$status" -eq 0 ]
}
