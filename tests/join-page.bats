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

@test "the page shows the last mod numbers and never reads GitHub or CurseForge itself" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  printf 'plugins:\n  - {name: A, summary: "Does a thing.", source: "https://github.com/o/r"}\n' >"$SN2_CONTROL_DIR/plugins.yaml"
  # Numbers past their six hours: a page that read stats itself would rewrite this file.
  printf '{"ts":1,"mods":{"A":{"site":"github","stars":4321,"updated":"2026-05-28","by":"o","project":"github:o/r"}}}\n' \
    >"$DATA_DIR/run/mod-stats.json"
  before=$(cat "$DATA_DIR/run/mod-stats.json")
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'4,321 on GitHub'* ]]
  [ "$(cat "$DATA_DIR/run/mod-stats.json")" = "$before" ]
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
  [[ "$output" == *'Voice</a></span><span class="facts"><span class="ver">1.2</span><span class="tag req">required</span></span></div><span class="about">Voice chat.</span></li>'* ]]
  [[ "$output" == *'nexusmods.com'* && "$output" == *'<span class="tag">optional</span><span class="tag">download from its page</span>'* ]]
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
  [ "$status" -eq 0 ]; [[ "$output" == *Sneaky* ]]; [[ "$output" != *javascript:* ]]
}

@test "a banner in templates shows at the top of the page and goes when it is removed" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  mkdir -p "$DATA_DIR/templates"
  printf 'png bytes' >"$DATA_DIR/templates/banner.png"
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'<header class="head"><img class="banner" src="banner.png?'"$(printf 'png bytes' | sha256sum | cut -c1-12)"'" alt=""><p class="readout">'* ]]
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

@test "the web server names a type for every kind of file the pages publish, so a browser applies the stylesheet" {
  conf=$(sed -n '/^mimetype.assign/,/)$/p' "$ROOT/scripts/mod-service.sh")
  for ext in .html .json .png .css .jpg .jpeg .webp .gif .zip; do
    [[ "$conf" == *"\"$ext\" =>"* ]] || { echo "no type for $ext"; false; }
  done
  [[ "$conf" == *'".css" => "text/css'* ]]
}

@test "the web server takes its config without a warning, sends / to the join page and lists no folder" {
  command -v lighttpd >/dev/null || skip "lighttpd not installed (the pre-commit image adds it)"
  mkdir -p "$DATA_DIR/public/files"
  echo page >"$DATA_DIR/public/join.html"; echo zip >"$DATA_DIR/public/files/a.zip"
  SN2_MODS_PORT=18081 bash "$ROOT/scripts/mod-service.sh" web-config >"$BATS_TEST_TMPDIR/web.conf"
  run lighttpd -tt -f "$BATS_TEST_TMPDIR/web.conf"
  [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "lighttpd said: $output"; false; }
  lighttpd -D -f "$BATS_TEST_TMPDIR/web.conf" & web=$!
  ask() { python3 - "$1" <<'PY'
import sys, urllib.request, urllib.error
class NoFollow(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
try:
    r = urllib.request.build_opener(NoFollow).open("http://127.0.0.1:18081" + sys.argv[1], timeout=5)
    print(r.status, r.headers.get("Content-Type", ""), r.headers.get("Location", ""))
except urllib.error.HTTPError as e:
    print(e.code, e.headers.get("Content-Type", ""), e.headers.get("Location", ""))
PY
  }
  for _ in 1 2 3 4 5 6 7 8 9 10; do ask /join.html 2>/dev/null | grep -q '^200' && break; sleep 0.3; done
  root=$(ask /); folder=$(ask /files/); zip=$(ask /files/a.zip)
  kill "$web" 2>/dev/null || true
  [[ "$root" == 301*"/join.html" ]] || { echo "/ gave: $root"; false; }
  [[ "$folder" == 403* ]] || { echo "/files/ gave: $folder"; false; }
  [[ "$zip" == "200 application/zip"* ]] || { echo "the zip gave: $zip"; false; }
}

@test "the page links theme.css by a fingerprint of its content, and a host's own theme changes it" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  run render
  [ "$status" -eq 0 ]
  shipped=$(printf '%s' "$output" | grep -o 'theme\.css?[0-9a-f]*')
  [ "${#shipped}" -eq 22 ]
  cmp "$ROOT/web/theme.css" "$DATA_DIR/public/theme.css"
  mkdir -p "$DATA_DIR/templates"
  printf ':root { --ink: #000000; }\n' >"$DATA_DIR/templates/theme.css"
  run render
  own=$(printf '%s' "$output" | grep -o 'theme\.css?[0-9a-f]*')
  [ "${#own}" -eq 22 ] && [ "$own" != "$shipped" ]
  grep -q -- '--ink: #000000' "$DATA_DIR/public/theme.css"
}

@test "the page names the game, at the top and in its title" {
  command -v python3 >/dev/null || skip "python3 not installed (the pre-commit image adds it)"
  run render
  [ "$status" -eq 0 ]
  [[ "$output" == *'<title>Join Slot1 · Subnautica 2</title>'* ]]
  [[ "$output" == *'<p class="readout"><span class="game">Subnautica 2</span>'*'<h1>Join Slot1</h1>'* ]]
}
