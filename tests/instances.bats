#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/bin" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../bin/moonpool-instance" "$ROOT/bin/"
  cp "$BATS_TEST_DIRNAME/../.env.example" "$ROOT/"
  printf 'services: {}\n' >"$ROOT/compose.yaml"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
if [ "$1 $2" = "compose version" ]; then exit 0; fi
if [ "$1" = ps ]; then echo '0.0.0.0:9000->8080/tcp'; exit 0; fi
case " $* " in
  *" ps --status running -q "*) [ -z "${STUB_RUNNING:-}" ] || echo cafe0000 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker" "$ROOT/bin/moonpool-instance"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" CALLS
  INSTANCE=(env SN2_ROOT="$ROOT" "$ROOT/bin/moonpool-instance")
}

@test "add creates an isolated env with unique ports and names" {
  run "${INSTANCE[@]}" add family
  [ "$status" -eq 0 ]
  env="$ROOT/instances/family/.env"
  [ -f "$env" ]
  grep -qx 'COMPOSE_PROJECT_NAME=sn2-family' "$env"
  grep -qx 'SN2_CONTAINER_NAME=sn2-family' "$env"
  # The container reads this file, never the default world's .env (its webhook, its board).
  grep -qx 'SN2_ENV_FILE=instances/family/.env' "$env"
  grep -qx 'WORLD_NAME=family' "$env"
  grep -qx 'NOVNC_PORT=8082' "$env"
  grep -qx 'SN2_MODS_PORT=8083' "$env"

  run "${INSTANCE[@]}" add friends
  [ "$status" -eq 0 ]
  [ "$(grep '^NOVNC_PORT=' "$ROOT/instances/friends/.env")" = NOVNC_PORT=8084 ]
  [ "$(grep '^SN2_MODS_PORT=' "$ROOT/instances/friends/.env")" = SN2_MODS_PORT=8085 ]
}

@test "list reports project container ports and state" {
  "${INSTANCE[@]}" add family >/dev/null
  run env STUB_RUNNING=1 "${INSTANCE[@]}" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"*"moonpool"*"8080,8081"* ]]
  [[ "$output" == *"family"*"sn2-family"*"8082,8083"*"up"* ]]
}

@test "rm refuses a running instance and requires volume confirmation twice" {
  "${INSTANCE[@]}" add family >/dev/null
  run env STUB_RUNNING=1 "${INSTANCE[@]}" rm family
  [ "$status" -eq 69 ]
  [ -f "$ROOT/instances/family/.env" ]

  run "${INSTANCE[@]}" rm family --volumes
  [ "$status" -eq 64 ]
  [ -f "$ROOT/instances/family/.env" ]

  run "${INSTANCE[@]}" rm family --volumes --volumes
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/instances/family" ]
  grep -q -- 'down --volumes' "$CALLS"
}

@test "rm keeps the volume unless explicitly confirmed" {
  "${INSTANCE[@]}" add family >/dev/null
  run "${INSTANCE[@]}" rm family
  [ "$status" -eq 0 ]
  grep -q ' down$' "$CALLS"
  run ! grep -q -- 'down --volumes' "$CALLS"
}

@test "moonpool selects the requested compose project and env file" {
  mkdir -p "$ROOT/instances/reef"
  : >"$ROOT/instances/reef/.env"
  run env -u SN2_IN_CONTAINER SN2_REPO_ROOT="$ROOT" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    "$BATS_TEST_DIRNAME/../bin/moonpool" --instance reef players
  [ "$status" -eq 69 ]
  grep -q -- "-p sn2-reef --env-file $ROOT/instances/reef/.env -f $ROOT/compose.yaml ps -q sn2" "$CALLS"
}

@test "moonpool validates instance names and preserves the default compose invocation" {
  run env -u SN2_IN_CONTAINER SN2_REPO_ROOT="$ROOT" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    "$BATS_TEST_DIRNAME/../bin/moonpool" --instance Nope players
  [ "$status" -eq 64 ]

  : >"$CALLS"
  run env -u SN2_IN_CONTAINER PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    "$BATS_TEST_DIRNAME/../bin/moonpool" players
  [ "$status" -eq 69 ]
  grep -q '^compose ps -q sn2$' "$CALLS"
  run ! grep -q -- '--env-file' "$CALLS"
}

@test "add sets the Steam branch when given, and rejects an unknown one" {
  run "${INSTANCE[@]}" add dev experimental
  [ "$status" -eq 0 ]
  grep -qx 'STEAM_BRANCH=experimental' "$ROOT/instances/dev/.env"
  run "${INSTANCE[@]}" add stable public
  [ "$status" -eq 0 ]
  grep -qx 'STEAM_BRANCH=public' "$ROOT/instances/stable/.env"
  run "${INSTANCE[@]}" add bad nonsense
  [ "$status" -eq 64 ]
  [ ! -e "$ROOT/instances/bad" ]
}
