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

@test "host pak mods are copied into ~mods, removed once taken out, and a link is never followed" {
  d="$TMPROOT/data"; g="$TMPROOT/game"; mods="$g/Subnautica2/Content/Paks/~mods"
  mkdir -p "$d/paks-local" "$d/run" "$mods"
  printf 'theirs' >"$mods/Other_P.pak"
  for ext in pak ucas utoc; do printf "v1 %s" "$ext" >"$d/paks-local/Big_P.$ext"; done
  printf 'secret' >"$TMPROOT/secret"; ln -s "$TMPROOT/secret" "$d/paks-local/Link_P.pak"
  apply() { run bash -c '. "$1/scripts/common.sh"; apply_local_paks' bash "$ROOT"; }
  export DATA_DIR="$d" GAME_DIR="$g" RUN_DIR="$d/run" LOG_DIR="$d/logs"
  apply
  [ "$status" -eq 0 ]
  [ "$(cat "$mods/Big_P.ucas")" = 'v1 ucas' ]
  [ ! -e "$mods/Link_P.pak" ]
  rm "$d/paks-local/Big_P.pak" "$d/paks-local/Big_P.ucas" "$d/paks-local/Big_P.utoc"
  apply
  [ "$status" -eq 0 ]
  [ ! -e "$mods/Big_P.pak" ] && [ ! -e "$mods/Big_P.utoc" ]
  [ "$(cat "$mods/Other_P.pak")" = 'theirs' ]
  # A file replaced since it was copied is not removed, and a forged list cannot reach outside ~mods.
  printf 'v2' >"$d/paks-local/Mine_P.pak"; apply; printf 'edited' >"$mods/Mine_P.pak"; rm "$d/paks-local/Mine_P.pak"
  printf 'keep' >"$g/Subnautica2/Content/Paks/Engine.ini"
  printf '%s ../Engine.ini\n' "$(printf keep | sha256sum | cut -d' ' -f1)" >>"$d/run/paks-local.list"
  apply
  [ "$(cat "$mods/Mine_P.pak")" = 'edited' ]
  [ "$(cat "$g/Subnautica2/Content/Paks/Engine.ini")" = 'keep' ]
  # A link already sitting in ~mods under a pak's name is not written through.
  ln -s "$TMPROOT/secret" "$mods/Big_P.pak"; printf 'v3' >"$d/paks-local/Big_P.pak"; apply
  [ "$(cat "$TMPROOT/secret")" = 'secret' ]
}
