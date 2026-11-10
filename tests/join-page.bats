#!/usr/bin/env bats
# A server with no published mods: the page leads with the plain Steam join and hands off by
# itself. With a published manifest the launcher leads, nothing joins by itself, and the plain
# join is a small link under it.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  export DATA_DIR="$BATS_TEST_TMPDIR/data"
  export SN2_CONTROL_DIR="$DATA_DIR/control"
  mkdir -p "$DATA_DIR/run" "$DATA_DIR/public" "$SN2_CONTROL_DIR"
  # The page build reads mod stats; a test never reaches GitHub or CurseForge.
  export GITHUB_API_URL="file://$BATS_TEST_TMPDIR/no-api" CURSEFORGE_API_URL="file://$BATS_TEST_TMPDIR/no-api"
  printf '{"lobby_id":"109775000000000001","host_steamid":"76561198000000001"}\n' >"$DATA_DIR/run/mod-session.json"
}
render() { env "$@" WORLD_NAME=Slot1 python3 "$ROOT/scripts/join-page.py"; cat "$DATA_DIR/public/join.html"; }

@test "an admin's templates/join.html.j2 replaces the page; one that cannot render gives the shipped page" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  mkdir -p "$DATA_DIR/templates"
  printf '<html><body>mine: {{ world }}</body></html>\n' >"$DATA_DIR/templates/join.html.j2"
  run render
  [ "$status" -eq 0 ]; [[ "$output" == *'mine: Slot1'* ]]; [[ "$output" != *'Join now'* ]]
  printf '<html>{{ nope }}</html>\n' >"$DATA_DIR/templates/join.html.j2"
  run render
  [ "$status" -eq 0 ]; [[ "$output" == *'>Join now</a>'* ]]; [[ "$output" == *'using the shipped page'* ]]
  printf '<html>{{ world.__class__ }}</html>\n' >"$DATA_DIR/templates/join.html.j2"
  run render
  [ "$status" -eq 0 ]; [[ "$output" == *'>Join now</a>'* ]]
}

@test "join is the hero; declared mods sit below it as links, no download" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'YAML'
plugins:
  - name: "Propulsion Tweaks"
    summary: "Match the host's vehicle speed."
    source: "https://www.curseforge.com/subnautica-2/ue4ss-mods/sn2propulsiontweaks"
    tier: mandatory
YAML
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'>Join now</a>'* ]]
  # the mod list comes AFTER the join button and links the mod's own page
  [[ "${output%%Propulsion Tweaks*}" == *'>Join now</a>'* ]]
  [[ "$output" == *'Propulsion Tweaks'* && "$output" == *'curseforge.com'* ]]
  # nothing is served or downloaded from the server
  [[ "$output" != *.zip* && "$output" != *moonpool.cmd* ]]
}

@test "once the publisher has a manifest, the page offers the launcher and says what it installs" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  cat >"$SN2_CONTROL_DIR/plugins.yaml" <<'YAML'
plugins:
  - { name: "Voice", summary: "Voice chat.", version: "1.2", tier: mandatory,
      install: { type: github, repo: a/b, tag: v1, asset: v.zip } }
  - { name: "Nexus FoV", tier: optional, install: { type: nexus, mod_id: 196, file_id: 1 } }
YAML
  printf '{"manifest_url":"https://mods.example/mods.json"}' >"$DATA_DIR/public/moonpool.json"
  cat >"$DATA_DIR/public/mods.json" <<'JSON'
{"schema":3,"mods":[
  {"name":"Voice","version":"1.2","required":true,"kind":"ue4ss","folder":"Voice","prefix":"",
   "source":{"type":"github","page":"https://github.com/a/b/releases/tag/v1","url":"https://github.com/a/b/releases/download/v1/v.zip","hashes":[]}},
  {"name":"Nexus FoV","version":"","required":false,"kind":"ue4ss","folder":"FoV","prefix":"",
   "source":{"type":"nexus","page":"https://www.nexusmods.com/subnautica2/mods/196?tab=files&file_id=1","url":"","hashes":[]}}]}
JSON
  run render
  [ "$status" -eq 0 ]
  # The launcher leads and nothing joins by itself: an automatic hand-off would skip it.
  [[ "$output" == *'href="moonpool:https://mods.example">Play with mods</a>'* ]]
  [[ "$output" == *'releases/latest/download/moonpool-setup.cmd">Get the launcher</a>'* ]]
  # The plain join is a small link under the launcher, never a button.
  [[ "$output" != *'Join now'* && "$output" != *'class="button ghost"'* ]]
  [[ "${output%%Join without mods*}" == *'Play with mods</a>'* && "$output" == *'href="steam://joinlobby/'*'>Join without mods</a>'* ]]
  [[ "$output" != *'http-equiv="refresh"'* && "$output" != *'location.href'* && "$output" != *'location.assign'* ]]
  # A click says at once what should open; the install steps show only if the page still has focus.
  [[ "$output" == *'id="opening" hidden'*'id="nothing" hidden'*'Still waiting?'* ]]
  [[ "$output" == *'Voice</a> 1.2<span class="about">Voice chat.</span></li>'* ]]
  [[ "$output" == *'nexusmods.com'* && "$output" == *'(optional, needs one download from its page)'* ]]
}

@test "an empty published list is a plain page that joins by itself" {
  printf '{"schema":3,"mods":[]}' >"$DATA_DIR/public/mods.json"
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'>Join now</a>'* && "$output" == *'http-equiv="refresh"'* && "$output" != *'Play with mods'* ]]
}

@test "no plugins.yaml shows only the plain join, no mod section" {
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'>Join now</a>'* ]]
  [[ "$output" != *'class="mods"'* ]]
}

@test "with no lobby yet the page is a retrying starting page" {
  rm -f "$DATA_DIR/run/mod-session.json"
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'The server is starting.'* ]]
}

@test "every supervised service has a case in sn2-service.sh, so the web root on 8081 cannot vanish" {
  runs=0 missing=""
  for run in "$ROOT"/docker/s6-overlay/s6-rc.d/*/run; do
    name=$(sed -nE 's#.*/opt/sn2/bin/sn2-service\.sh ([a-z0-9-]+).*#\1#p' "$run")
    [ -n "$name" ] || continue
    runs=$((runs + 1))
    grep -qE "^  ([a-z0-9|-]+ \| )*${name}( \| [a-z0-9|-]+)*\)" "$ROOT/docker/sn2-service.sh" || missing="$missing $name"
  done
  # A floor, so a moved s6 tree cannot pass by reading nothing.
  [ "$runs" -ge 8 ]
  [ -z "$missing" ] || { echo "s6 services with no sn2-service.sh case:$missing"; false; }
  # The mods case hands the root to mod-service.sh, which writes the lighttpd config.
  grep -qE '^  mods\)' "$ROOT/docker/sn2-service.sh"
  grep -q 'mod-service.sh serve' "$ROOT/docker/sn2-service.sh"
  # shellcheck disable=SC2016 # the literal config line, not an expansion
  grep -q 'server.document-root = "$DATA_DIR/public"' "$ROOT/scripts/mod-service.sh"
}

@test "a plugin link that is not http(s) renders as plain text" {
  printf 'plugins:\n  - name: Sneaky\n    source: "javascript:alert(1)"\n    install: { type: github, repo: a/b, tag: t, asset: a.zip }\n' >"$BATS_TEST_TMPDIR/p.yaml"
  run python3 "$ROOT/scripts/plugins-section.py" "$BATS_TEST_TMPDIR/p.yaml"
  [ "$status" -eq 0 ] && [[ "$output" == *Sneaky* ]] && [[ "$output" != *javascript:* ]]
}

@test "a banner in templates shows at the top of the page and goes when it is removed" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  mkdir -p "$DATA_DIR/templates"
  printf 'png bytes' >"$DATA_DIR/templates/banner.png"
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'<main class="card"><img class="banner" src="banner.png" alt=""><h1>'* ]]
  [ "$(cat "$DATA_DIR/public/banner.png")" = 'png bytes' ]
  rm "$DATA_DIR/templates/banner.png"
  run render
  [[ "$output" != *'class="banner"'* ]]
  [ ! -e "$DATA_DIR/public/banner.png" ]
  # A link named banner is never followed: it could point at any file the host can read.
  printf 'not for the web' >"$BATS_TEST_TMPDIR/secret"
  ln -s "$BATS_TEST_TMPDIR/secret" "$DATA_DIR/templates/banner.png"
  run render
  [[ "$output" != *'class="banner"'* ]]
  [ ! -e "$DATA_DIR/public/banner.png" ]
}
