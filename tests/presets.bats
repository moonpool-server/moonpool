#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
}

resolved() {
  # shellcheck disable=SC2016 # expanded by the deliberately separate bash -c process
  env -i PATH="$PATH" "$@" bash -c '. "$1/scripts/common.sh"; printf "%s|%s|%s|%s|%s|%s|%s|%s" "$PLAYER_SLOTS" "$STORY_GOALS" "$UNLOCK_REPLAY" "$LIFEPOD_JOIN_HOLD" "$VOICE_WARN" "$VOICE_RANGE_M" "$IDLE_FREEZE_MINUTES" "$IDLE_STOP_HOURS"' bash "$ROOT"
}

@test "friends and stock resolve their documented defaults" {
  run resolved PRESET=friends
  [ "$status" -eq 0 ]
  [ "$output" = "4|true|true|true|true|100|10|" ]
  run resolved PRESET=stock
  [ "$status" -eq 0 ]
  [ "$output" = "4|false|false|false|false|100|0|" ]
}

@test "an explicit switch wins over the preset" {
  run resolved PRESET=stock PLAYER_SLOTS=12 STORY_GOALS=true UNLOCK_REPLAY=true LIFEPOD_JOIN_HOLD=true VOICE_WARN=true VOICE_RANGE_M=125 IDLE_FREEZE_MINUTES=7 IDLE_STOP_HOURS=2
  [ "$status" -eq 0 ]
  [ "$output" = "12|true|true|true|true|125|7|2" ]
}

@test "an unknown preset is refused by name" {
  run resolved PRESET=arcade
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown PRESET arcade"* ]]
}

@test "env example and compose list the same behavior switches" {
  expected='AUTO_ACCEPT_FRIENDS HIDE_HOST_BODY IDLE_FREEZE_MINUTES IDLE_STOP_HOURS LIFEPOD_JOIN_HOLD PLAYER_SLOTS PRESET RESTART_CRON STORY_GOALS UNLOCK_REPLAY HOST_PRUNE VOICE_WARN VOICE_RANGE_M'
  expected=$(tr ' ' '\n' <<<"$expected" | sort)
  envs=$(sed -nE 's/^#? ?(AUTO_ACCEPT_FRIENDS|HIDE_HOST_BODY|IDLE_FREEZE_MINUTES|IDLE_STOP_HOURS|LIFEPOD_JOIN_HOLD|PLAYER_SLOTS|PRESET|RESTART_CRON|STORY_GOALS|UNLOCK_REPLAY|HOST_PRUNE|VOICE_WARN|VOICE_RANGE_M)=.*/\1/p' "$ROOT/.env.example" | sort)
  [ "$envs" = "$expected" ]
  # The fourth place: compose.yaml carries every .env setting into the container (env_file: .env) and
  # names each behavior switch, so none is forgotten here. Preset-driven switches are listed in the
  # env_file note, NOT pinned in environment: below, because resolve_preset only sets an unset var and
  # a compose default would override the friends/stock preset.
  grep -qE '^[[:space:]]*- path: \$\{SN2_ENV_FILE:-\.env\}$' "$ROOT/compose.yaml"
  compose=$(grep -oE '(AUTO_ACCEPT_FRIENDS|HIDE_HOST_BODY|IDLE_FREEZE_MINUTES|IDLE_STOP_HOURS|LIFEPOD_JOIN_HOLD|PLAYER_SLOTS|PRESET|RESTART_CRON|STORY_GOALS|UNLOCK_REPLAY|HOST_PRUNE|VOICE_WARN|VOICE_RANGE_M)' "$ROOT/compose.yaml" | sort -u)
  [ "$compose" = "$expected" ]
}
