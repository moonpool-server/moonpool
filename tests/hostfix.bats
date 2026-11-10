#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  TMPROOT=$(mktemp -d)
}

teardown() { rm -rf "$TMPROOT"; }

@test "background FPS updates only its existing setting" {
  ini="$TMPROOT/GameUserSettings.ini"
  printf '[Other]\nKeep=yes\nFrameRateLimit_WhenBackgrounded=30\nTail=yes\n' >"$ini"
  run bash -c '. "$1/scripts/common.sh"; set_background_fps "$2" 72' bash "$ROOT" "$ini"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^FrameRateLimit_WhenBackgrounded=' "$ini")" -eq 1 ]
  grep -q '^FrameRateLimit_WhenBackgrounded=72$' "$ini"
  grep -q '^Keep=yes$' "$ini"
  grep -q '^Tail=yes$' "$ini"
}

@test "background FPS creates a missing settings file" {
  ini="$TMPROOT/nested/GameUserSettings.ini"
  run bash -c '. "$1/scripts/common.sh"; set_background_fps "$2" 60' bash "$ROOT" "$ini"
  [ "$status" -eq 0 ]
  grep -q '^\[/Script/Subnautica2.SN2SettingsLocal\]$' "$ini"
  grep -q '^FrameRateLimit_WhenBackgrounded=60$' "$ini"
}

@test "background FPS rejects unsafe values" {
  ini="$TMPROOT/GameUserSettings.ini"
  run bash -c '. "$1/scripts/common.sh"; set_background_fps "$2" "60;bad"' bash "$ROOT" "$ini"
  [ "$status" -eq 2 ]
  [ ! -e "$ini" ]
}

@test "set_ini_key rewrites a key in place and never duplicates it" {
  ini="$TMPROOT/Engine.ini"
  run bash -c '. "$1/scripts/common.sh"; set_ini_key "$2" SomeSection AKey one' bash "$ROOT" "$ini"
  [ "$status" -eq 0 ]; grep -q '^\[SomeSection\]$' "$ini"; grep -q '^AKey=one$' "$ini"
  run bash -c '. "$1/scripts/common.sh"; set_ini_key "$2" SomeSection AKey two' bash "$ROOT" "$ini"
  [ "$(grep -c '^AKey=' "$ini")" -eq 1 ]; grep -q '^AKey=two$' "$ini"
  # Disabling the host's EOS voice is not an option: the lobby needs its RTC room, so launch
  # never writes bUseEOSRTC.
  run ! grep -q bUseEOSRTC "$ROOT/scripts/launch-headless.sh"
}
