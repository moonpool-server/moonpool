#!/usr/bin/env bats
# control/plugins.yaml is the admin's one mod list. The publisher turns every enabled,
# player-side entry with an install: block into one signed manifest (schema 3) plus the
# moonpool launcher's server config; entries without one stay links on the join page. Nothing is
# guessed: a GitHub asset is hashed when first seen and refused if it changes under its
# tag; a Nexus file is published only once the admin has pinned the archive by hand.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  CTL="$ROOT/bin/moonpool"
  export DATA_DIR="$BATS_TEST_TMPDIR/data"
  export SN2_CONTROL_DIR="$DATA_DIR/control"
  export SN2_IN_CONTAINER=1 SN2_BIN="$ROOT/scripts"
  export WINEPREFIX="$DATA_DIR/wine" STEAM_BRANCH=experimental HOST_NAME="Test Host"
  export SN2_PUBLIC_URL="https://mods.example:8081" SN2_MODS_PORT=8081 UE4SS_CHANNEL=pinned
  mkdir -p "$SN2_CONTROL_DIR" "$DATA_DIR/run" "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps"
  chmod 700 "$SN2_CONTROL_DIR"
  printf '{"lobby_id":"0x10","host_steamid":"76561198000000000"}\n' >"$DATA_DIR/run/mod-session.json"
  # Shaped like the file Steam writes: one key per line, the branch under UserConfig.
  printf '"AppState"\n{\n\t"buildid"\t\t"4242"\n\t"installdir"\t\t"Subnautica2"\n\t"UserConfig"\n\t{\n\t\t"BetaKey"\t\t"experimental"\n\t}\n}\n' \
    >"$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_1962700.acf"
  # The host's own executable: the loader players get is allowed on exactly this build.
  exe=$(bash -c '. "$1/scripts/common.sh"; printf "%s/%s" "$WIN64_DIR" "$GAME_EXE_NAME"' _ "$ROOT")
  mkdir -p "$(dirname "$exe")"; printf 'not really the game\n' >"$exe"
  EXE_SHA=$(sha256sum "$exe" | cut -d' ' -f1)
  mkdir -p "$DATA_DIR/client-mods/Loader/Scripts"
  printf 'print("hello")\n' >"$DATA_DIR/client-mods/Loader/Scripts/main.lua"
}

local_mod_yaml() {
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'EOF'
plugins:
  - name: Loader
    summary: the server's own mod
    version: "1.0"
    tier: mandatory
    install: { type: local, kind: ue4ss }
EOF
}

# A zip laid out like a release asset: paths inside it as given, content "<path> v<n>".
make_zip() { # out.zip version path...
  local out=$1 v=$2 d; shift 2
  d=$(mktemp -d); for p in "$@"; do mkdir -p "$d/$(dirname "$p")"; printf '%s v%s\n' "$p" "$v" >"$d/$p"; done
  (cd "$d" && zip -q -r "$out" .)
  rm -rf "$d"
}

@test "a local UE4SS mod publishes a signed schema 3 manifest, the loader pin and the config, and serves no launcher" {
  local_mod_yaml
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.enabled, .mods, .required, .ue4ss' <<<"$output")" = $'true\n1\n1\ntrue' ]
  m="$DATA_DIR/public/mods.json"
  [ "$(jq -r '.schema, .game.buildid, .game.branch, .session.lobby_id' "$m")" = $'3\n4242\nexperimental\n16' ]
  [ "$(jq -r '.mods[0] | .name, .kind, .folder, .prefix, .required, .source.type, .source.url' "$m")" = \
    $'Loader\nue4ss\nLoader\n\ntrue\nlocal\nfiles/Loader.zip' ]
  [ "$(jq -r '.mods[0].source.hashes[0].value' "$m")" = "$(sha256sum "$DATA_DIR/public/files/Loader.zip" | cut -d' ' -f1)" ]
  unzip -l "$DATA_DIR/public/files/Loader.zip" | grep -q 'Scripts/main.lua'
  [ "$(jq -r '.ue4ss.asset, .ue4ss.allowed_builds[0]' "$m")" = $'UE4SS_v3.0.1-1188-gf885e8d2.zip\n'"$EXE_SHA" ]
  # No verified copy on the host: the mirror address. With one: served from the host itself.
  [[ "$(jq -r '.ue4ss.url' "$m")" == https://github.com/*/UE4SS_v3.0.1-1188-gf885e8d2.zip ]]
  mkdir -p "$DATA_DIR/ue4ss"; printf 'loader bytes\n' >"$DATA_DIR/ue4ss/UE4SS_test.zip"
  run env UE4SS_ASSET=UE4SS_test.zip UE4SS_RELEASE_SHA256="$(sha256sum "$DATA_DIR/ue4ss/UE4SS_test.zip" | cut -d' ' -f1)" \
    "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ue4ss.url' "$m")" = files/UE4SS_test.zip ]
  cmp -s "$DATA_DIR/ue4ss/UE4SS_test.zip" "$DATA_DIR/public/files/UE4SS_test.zip"
  openssl dgst -sha256 -verify "$DATA_DIR/mod-signing/public.pem" -signature "$DATA_DIR/public/mods.json.sig" "$m"
  jq -e '.manifest_url == "https://mods.example:8081/mods.json" and .public_key.modulus != "" and
         .host_steamid == "76561198000000000" and (.server_id | length) == 16' "$DATA_DIR/public/moonpool.json"
  [ ! -e "$DATA_DIR/public/moonpool.ps1" ] && [ ! -e "$DATA_DIR/public/moonpool.cmd" ] && [ ! -e "$DATA_DIR/public/sn2-launcher.zip" ]
  [ "$(jq -r 'has("launcher")' "$m")" = false ]
}

@test "off, host-only and link-only entries never reach players; link-only ones are reported" {
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'EOF'
plugins:
  - { name: Loader, tier: mandatory, install: { type: local, kind: ue4ss } }
  - { name: Switched Off, tier: mandatory, enabled: false, install: { type: local, kind: ue4ss } }
  - { name: Cap Raiser, side: host, install: { type: github, repo: a/b, tag: v1, asset: x.zip } }
  - { name: Just A Link, source: "https://www.nexusmods.com/subnautica2/mods/1", tier: optional }
EOF
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mods, .linked, .skipped' <<<"$output")" = $'1
["Just A Link"]
[]' ]
  [ "$(jq -r '.mods | length' "$DATA_DIR/public/mods.json")" -eq 1 ]
}

@test "a Nexus file is published only after mods pin recorded its archive; players then download it themselves" {
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'EOF'
plugins:
  - name: Nexus Thing
    tier: optional
    version: "2.1"
    install: { type: nexus, mod_id: 196, file_id: 777, kind: ue4ss }
EOF
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ]
  [ "$(jq -r '.enabled, .skipped[0].name' <<<"$output")" = $'false\nNexus Thing' ]
  [[ "$(jq -r '.skipped[0].reason' <<<"$output")" == *'moonpool mods pin'* ]]
  [ ! -e "$DATA_DIR/public/mods.json" ]
  make_zip "$BATS_TEST_TMPDIR/NexusThing-2.1.zip" 1 'NexusThing/Scripts/main.lua' 'NexusThing/readme.txt'
  run "$CTL" --json mods pin "Nexus Thing" "$BATS_TEST_TMPDIR/NexusThing-2.1.zip"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.command, .ok, .data.mods_in_archive[0]' <<<"$output")" = $'mods.pin\ntrue\nNexusThing' ]
  grep -q 'sha256:' "$SN2_CONTROL_DIR/plugins.yaml"
  grep -q 'file_name: NexusThing-2.1.zip' "$SN2_CONTROL_DIR/plugins.yaml"
  m="$DATA_DIR/public/mods.json"
  [ "$(jq -r '.mods[0] | .name, .required, .folder, .prefix, .source.type, .source.url, .source.file_name' "$m")" = \
    $'Nexus Thing\nfalse\nNexusThing\nNexusThing\nnexus\n\nNexusThing-2.1.zip' ]
  [ "$(jq -r '.mods[0].source.page' "$m")" = 'https://www.nexusmods.com/subnautica2/mods/196?tab=files&file_id=777' ]
  [ "$(jq -r '.mods[0].source.hashes[0].value' "$m")" = "$(sha256sum "$BATS_TEST_TMPDIR/NexusThing-2.1.zip" | cut -d' ' -f1)" ]
}

@test "a GitHub asset is hashed when first seen and refused when its bytes change under the same tag" {
  gh="$BATS_TEST_TMPDIR/gh"; rel="$gh/Someone/Thing/releases/download/v1"; mkdir -p "$rel"
  make_zip "$rel/Thing.zip" 1 'Thing/Scripts/main.lua'
  # shellcheck disable=SC2030,SC2031 # each test sets its own source address
  export SN2_GITHUB_BASE="file://$gh"
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'EOF'
plugins:
  - { name: Thing, tier: mandatory, install: { type: github, repo: Someone/Thing, tag: v1, asset: Thing.zip } }
EOF
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.mods' <<<"$output")" = 1 ]
  sha=$(sha256sum "$rel/Thing.zip" | cut -d' ' -f1)
  [ "$(jq -r '.["github:Someone/Thing@v1/Thing.zip"].sha256' "$DATA_DIR/mods-pins.json")" = "$sha" ]
  [ "$(jq -r '.mods[0].source.url' "$DATA_DIR/public/mods.json")" = "file://$gh/Someone/Thing/releases/download/v1/Thing.zip" ]
  rm "$rel/Thing.zip"; make_zip "$rel/Thing.zip" 2 'Thing/Scripts/main.lua'
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ]
  # Refused, and players keep the version they had: the mod does not vanish from the list.
  [ "$(jq -r '.mods' <<<"$output")" = 1 ]
  [[ "$(jq -r '.skipped[0].reason' <<<"$output")" == *'changed'*'players keep the last published version'* ]]
  [ "$(jq -r '.mods[0].source.hashes[0].value' "$DATA_DIR/public/mods.json")" = "$sha" ]
  # Re-pinning on purpose takes the new bytes.
  run "$CTL" --json mods pin Thing "$rel/Thing.zip"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.mods[0].source.hashes[0].value' "$DATA_DIR/public/mods.json")" = "$(sha256sum "$rel/Thing.zip" | cut -d' ' -f1)" ]
}

@test "the service loop makes no download for an unchanged entry, and an outage takes no mod away" {
  gh="$BATS_TEST_TMPDIR/gh"; rel="$gh/Someone/Thing/releases/download/v1"; mkdir -p "$rel"
  make_zip "$rel/Thing.zip" 1 'Thing/Scripts/main.lua'
  # shellcheck disable=SC2030,SC2031 # each test sets its own source address
  export SN2_GITHUB_BASE="file://$gh"
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'EOF'
plugins:
  - { name: Thing, tier: mandatory, install: { type: github, repo: Someone/Thing, tag: v1, asset: Thing.zip } }
EOF
  "$ROOT/scripts/mod-service.sh" publish >/dev/null
  mv "$gh" "$gh.gone"   # the source is down
  # The loop's own call, with no source reachable: nothing is fetched and nothing is reported.
  run python3 "$ROOT/scripts/publish-mods.py" --data-dir "$DATA_DIR" --plugins "$SN2_CONTROL_DIR/plugins.yaml" \
    --public-url https://mods.example:8081 --cached publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -c '.mods, .skipped' <<<"$output")" = $'1\n[]' ]
  # An explicit publish tries the source, fails, and keeps the mod for players.
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mods' <<<"$output")" = 1 ]
  [[ "$(jq -r '.skipped[0].reason' <<<"$output")" == *'players keep the last published version'* ]]
  [ "$(jq -r '.mods | length' "$DATA_DIR/public/mods.json")" -eq 1 ]
}

@test "with no public address yet nothing broken is published and what was published stays" {
  local_mod_yaml
  "$ROOT/scripts/mod-service.sh" publish >/dev/null
  before=$(cat "$DATA_DIR/public/moonpool.json")
  run env SN2_PUBLIC_URL= TUNNEL=off "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -ne 0 ]
  [[ "$(jq -r '.error' <<<"$output")" == *'no public address'* ]]
  [ "$(cat "$DATA_DIR/public/moonpool.json")" = "$before" ]
  # Dropping the last mod with no address yet keeps the published pair and its downloads.
  printf 'plugins: []\n' >"$SN2_CONTROL_DIR/plugins.yaml"
  run env SN2_PUBLIC_URL= TUNNEL=off "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -ne 0 ]
  [ -e "$DATA_DIR/public/files/Loader.zip" ]
  [ "$(jq -r '.mods | length' "$DATA_DIR/public/mods.json")" -eq 1 ]
}

@test "a bundle holding several mods needs install.folder to say which one" {
  mkdir -p "$DATA_DIR/client-mods/Bundle/A/Scripts" "$DATA_DIR/client-mods/Bundle/B/Scripts"
  printf 'a\n' >"$DATA_DIR/client-mods/Bundle/A/Scripts/main.lua"; printf 'b\n' >"$DATA_DIR/client-mods/Bundle/B/Scripts/main.lua"
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'EOF'
plugins:
  - { name: Bundle, tier: mandatory, install: { type: local, kind: ue4ss } }
EOF
  run "$ROOT/scripts/mod-service.sh" publish
  [[ "$(jq -r '.skipped[0].reason' <<<"$output")" == *'install.folder'* ]]
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'EOF'
plugins:
  - { name: Bundle, tier: mandatory, install: { type: local, kind: ue4ss, folder: B } }
EOF
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$(jq -r '.mods[0].folder, .mods[0].prefix' "$DATA_DIR/public/mods.json")" = $'B\nB' ]
}

@test "moonpool mods: publish is receipted, list reads the envelope, disable and enable republish" {
  local_mod_yaml
  run "$CTL" --json mods publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.command, .state, .data.mods' <<<"$output")" = $'mods.publish\nverified\n1' ]
  [ "$(jq -r .command "$SN2_CONTROL_DIR/receipts.jsonl")" = mods.publish ]
  run "$CTL" --json mods list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.command, .data.mods[0].name, .data.mods[0].automatic, .data.ue4ss' <<<"$output")" = \
    $'mods.list\nLoader\ntrue\nUE4SS_v3.0.1-1188-gf885e8d2.zip' ]
  run "$CTL" mods list
  [[ "$output" == *'Loader 1.0  required  ue4ss -> Loader  installed by the launcher'* ]]
  run "$CTL" --json mods disable Loader
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'enabled: false' "$SN2_CONTROL_DIR/plugins.yaml"
  [ "$(jq -c '.mods' "$DATA_DIR/public/mods.json")" = '[]' ]
  run "$CTL" --json mods enable Loader
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mods | length' "$DATA_DIR/public/mods.json")" -eq 1 ]
  run "$CTL" mods
  [ "$status" -ne 0 ]
  [[ "$output" == *'usage: moonpool mods list | publish [plugins.yaml] | pin'* ]]
}

@test "moonpool mods publish --from installs the uploaded list first, then publishes it" {
  printf 'plugins:\n  - name: Loader\n    version: "2.0"\n    tier: mandatory\n    install: { type: local, kind: ue4ss }\n' >"$BATS_TEST_TMPDIR/new.yaml"
  run "$CTL" --json mods publish --from "$BATS_TEST_TMPDIR/new.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.data.mods' <<<"$output")" -eq 1 ]
  grep -q 'version: "2.0"' "$SN2_CONTROL_DIR/plugins.yaml"
  [ ! -e "$BATS_TEST_TMPDIR/new.yaml" ]
  [ "$(jq -r '.mods[0].version' "$DATA_DIR/public/mods.json")" = "2.0" ]
  run "$CTL" mods publish extra words
  [ "$status" -ne 0 ]
}

@test "a server that never listed a mod publishes nothing; one that drops its last mod publishes an empty signed list" {
  printf 'plugins: []\n' >"$SN2_CONTROL_DIR/plugins.yaml"
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ]
  [ "$(jq -r '.enabled' <<<"$output")" = false ]
  [ ! -e "$DATA_DIR/public/mods.json" ] && [ ! -e "$DATA_DIR/public/moonpool.json" ]
  local_mod_yaml
  "$ROOT/scripts/mod-service.sh" publish >/dev/null
  printf 'plugins: []\n' >"$SN2_CONTROL_DIR/plugins.yaml"
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ]
  # Players' shortcuts still ask this address: the list says "none", so they clear their set.
  [ "$(jq -r '.enabled' <<<"$output")" = false ]
  [ "$(jq -c '.mods' "$DATA_DIR/public/mods.json")" = '[]' ]
  openssl dgst -sha256 -verify "$DATA_DIR/mod-signing/public.pem" -signature "$DATA_DIR/public/mods.json.sig" "$DATA_DIR/public/mods.json"
  [ -z "$(ls -A "$DATA_DIR/public/files" 2>/dev/null)" ]
}

@test "a public address must be a plain URL, and plain http stays on a private network" {
  local_mod_yaml
  SN2_PUBLIC_URL="https://host/'; Start-Process calc; #" run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -ne 0 ] && [[ "$output" == *'not a plain http(s) address'* ]]
  [ ! -e "$DATA_DIR/public/moonpool.json" ]
  SN2_PUBLIC_URL="http://mods.example:8081" run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -ne 0 ] && [[ "$output" == *'must be https://'* ]]
  SN2_PUBLIC_URL="http://192.168.0.10:8081" run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the launcher an older image served is taken down" {
  local_mod_yaml
  mkdir -p "$DATA_DIR/public"; : >"$DATA_DIR/public/sn2-join.cmd"; : >"$DATA_DIR/public/sn2-join.ps1"; : >"$DATA_DIR/public/sn2-launcher.zip"
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$DATA_DIR/public/sn2-join.cmd" ] && [ ! -e "$DATA_DIR/public/sn2-join.ps1" ] && [ ! -e "$DATA_DIR/public/sn2-launcher.zip" ]
}

@test "a file off the list stops being served" {
  local_mod_yaml
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  : >"$DATA_DIR/public/files/Removed.zip"
  run "$ROOT/scripts/mod-service.sh" publish
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$DATA_DIR/public/files/Removed.zip" ] && [ -e "$DATA_DIR/public/files/Loader.zip" ]
}
