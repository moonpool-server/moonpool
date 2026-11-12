#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  export DATA_DIR="$BATS_TEST_TMPDIR/data"
  export RUN_DIR="$DATA_DIR/run" PUBLIC_DIR="$DATA_DIR/public"
  export CONTROL_DIR="$DATA_DIR/control" LOG_DIR="$DATA_DIR/logs" WORLD_NAME="Deep Blue"
  mkdir -p "$RUN_DIR" "$PUBLIC_DIR" "$CONTROL_DIR" "$LOG_DIR"
  # The page build reads mod stats; a test never reaches GitHub or CurseForge.
  export GITHUB_API_URL="file://$BATS_TEST_TMPDIR/no-api" CURSEFORGE_API_URL="file://$BATS_TEST_TMPDIR/no-api"
  rm -f "$RUN_DIR/mod-session.json"
}

fake_discord() {
  FAKE="$BATS_TEST_TMPDIR/fake-discord"; mkdir -p "$FAKE/peer"
  python3 "$ROOT/tests/fake_discord.py" "$FAKE" >/dev/null 2>&1 &
  FAKE_PID=$!
  for _ in $(seq 1 50); do [ -s "$FAKE/port" ] && break; sleep 0.1; done
  export DISCORD_CALLS="$FAKE/calls" DISCORD_BODIES="$FAKE/bodies"
  local port; port=$(cat "$FAKE/port")
  export DISCORD_WEBHOOK_URL="http://127.0.0.1:$port/api/webhooks/1/token"
}
teardown() { [ -z "${FAKE_PID:-}" ] || kill "$FAKE_PID" 2>/dev/null || true; }

map_status() {
  printf '%s' '{"ts":1700000000,"lifepod":{"x":1,"y":2},"bases":[],"players":[{"name":"Alice","x":5,"y":6,"depth_m":7}]}' >"$CONTROL_DIR/status.json"
}

@test "join page hands a current lobby to Steam and links the host profile" {
  printf '{"lobby_id":"0x10","host_steamid":"76561198000000000"}' >"$RUN_DIR/mod-session.json"
  python3 "$ROOT/scripts/join-page.py"
  grep -Fq 'steam://joinlobby/1962700/16/76561198000000000' "$PUBLIC_DIR/join.html"
  grep -Fq 'Join now' "$PUBLIC_DIR/join.html"
  grep -Fq 'https://steamcommunity.com/profiles/76561198000000000' "$PUBLIC_DIR/join.html"
  grep -Fq 'Launching Subnautica 2 &middot; you can close this tab' "$PUBLIC_DIR/join.html"
  grep -Fq 'Always allow' "$PUBLIC_DIR/join.html"
  # It closes once the game covers it, or from the button; never on a timer, which closed the
  # tab, and Steam's prompt with it, while a first-timer was still answering it.
  grep -Fq 'document.addEventListener("visibilitychange",function(){if(document.hidden){window.close()}})' "$PUBLIC_DIR/join.html"
  grep -Fq '<button class="close" id="close" type="button" hidden>Close this tab</button>' "$PUBLIC_DIR/join.html"
  run ! grep -Eq 'window\.close\(\)[^}]*\},[0-9]+\)' "$PUBLIC_DIR/join.html"
  # The link and meta refresh are the no-JavaScript path.
  grep -Fq '<a class="button" href="steam://joinlobby/1962700/16/76561198000000000">Join now</a>' "$PUBLIC_DIR/join.html"
  grep -Fq '<meta http-equiv="refresh" content="1;url=steam://joinlobby/1962700/16/76561198000000000">' "$PUBLIC_DIR/join.html"
}

@test "join page is a retrying starting page without a lobby or after host down" {
  python3 "$ROOT/scripts/join-page.py"
  grep -Fq 'The server is starting.' "$PUBLIC_DIR/join.html"
  run ! grep -q 'steam://joinlobby' "$PUBLIC_DIR/join.html"
  printf '{"lobby_id":"12","host_steamid":"76561198000000000"}' >"$RUN_DIR/mod-session.json"
  python3 "$ROOT/scripts/join-page.py"
  rm "$RUN_DIR/mod-session.json"
  python3 "$ROOT/scripts/join-page.py"
  grep -Fq 'The server is starting.' "$PUBLIC_DIR/join.html"
  run ! grep -q 'steam://joinlobby' "$PUBLIC_DIR/join.html"
}

@test "join page names the server's Steam branch and build, and how to match it" {
  m="$BATS_TEST_TMPDIR/appmanifest_1962700.acf"
  printf '"AppState"\n{\n\t"buildid"\t\t"26283380"\n\t"MountedConfig"\n\t{\n\t\t"BetaKey"\t\t"experimental"\n\t}\n}\n' >"$m"
  SN2_APPMANIFEST="$m" python3 "$ROOT/scripts/join-page.py"
  grep -Fq 'Experimental branch</span><span>Build 26283380' "$PUBLIC_DIR/join.html"
  grep -Fq 'Betas &rsaquo; <strong>experimental</strong>' "$PUBLIC_DIR/join.html"
  printf '"AppState"\n{\n\t"buildid"\t\t"1"\n}\n' >"$m"
  STEAM_BRANCH='' SN2_APPMANIFEST="$m" python3 "$ROOT/scripts/join-page.py"
  grep -Fq 'Public branch</span><span>Build 1' "$PUBLIC_DIR/join.html"
  run ! grep -q 'Betas &rsaquo;' "$PUBLIC_DIR/join.html"
}

@test "Discord card is one Components V2 panel led by a Join link button, in player-facing wording" {
  printf '{"ts":1700000000,"world_name":"Deep Blue","players":[{"name":"Alice"}],"sonar_code":"ABCD"}' >"$CONTROL_DIR/status.json"
  body=$(SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example HOST_NAME=Host \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  # V2 (1<<15) and silent (1<<12); a V2 message carries no content and no embeds.
  [ "$(jq .flags <<<"$body")" -eq 36864 ]
  [ "$(jq 'has("content") or has("embeds")' <<<"$body")" = false ]
  panel=$(jq -c '.components[0]' <<<"$body")
  [ "$(jq .type <<<"$panel")" -eq 17 ]
  head=$(jq -c '.components[0]' <<<"$panel")
  [ "$(jq .type <<<"$head")" -eq 9 ]
  [ "$(jq -r '.accessory | "\(.style) \(.url) \(.label) \(.disabled)"' <<<"$head")" = '5 https://play.example/join Offline true' ]
  [[ $(jq -r '.components[0].content' <<<"$head") == '## 🌊 Deep Blue'$'\n''🔴 **Down** since <t:1700000000:R>'* ]]
  [[ $panel == *'**Xbox** add code **ABCD**'* ]]
  [[ $(jq -r '.components[-1].content' <<<"$body") == *'How to join'* ]]
  # No map on the card: no media gallery, nothing that loads an image.
  [ "$(jq '[.. | objects | select(.type == 12)] | length' <<<"$body")" -eq 0 ]
  run ! grep -qiE 'sonar code|webhook|lobby id' <<<"$panel"
}

@test "Discord card clamps each world's text so three fit one message, and keeps its header and Join button" {
  printf '{"ts":1700000000,"world_name":"Deep Blue","players":[]}' >"$CONTROL_DIR/status.json"
  long=$(printf 'H%.0s' {1..5000})
  body=$(SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example HOST_NAME="$long" \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  size=$(jq '[.. | objects | select(.type == 10) | .content | length] | add' <<<"$body")
  [ "$size" -le 1300 ]
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == '## 🌊 Deep Blue'* ]]
  [ "$(jq -r '.components[0].components[0].accessory.url' <<<"$body")" = https://play.example/join ]
}

@test "Discord card says the time of day, the weather and recent scans in plain words" {
  printf '{"ts":1700000000,"state":"up","time_of_day":"15:30","weather":"DA_CloudyB","unlocks":{"scans":["Repair Tool","Bioreactor","Tadpole","Single Bed"]},"players":[]}' >"$CONTROL_DIR/status.json"
  printf up >"$DATA_DIR/discord/override" 2>/dev/null || { mkdir -p "$DATA_DIR/discord"; printf up >"$DATA_DIR/discord/override"; }
  printf 9999999999 >"$DATA_DIR/discord/override.expires"
  body=$(SN2_NOW=1700000000 python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $body == *'Afternoon · Cloudy'* ]]
  [[ $body == *'Scanned lately: Bioreactor, Tadpole, Single Bed'* ]]
  [[ $body != *DA_* ]]
}

@test "the admin's hook gets each event and a broken one holds nothing up" {
  printf '{"ts":1700000000,"players":[]}' >"$CONTROL_DIR/status.json"
  mkdir -p "$DATA_DIR/hooks"
  # shellcheck disable=SC2016  # the script is written literally
  printf '#!/bin/sh\necho "$1|$2" >>"$DATA_DIR/hook.out"\nexit 3\n' >"$DATA_DIR/hooks/on-event"
  chmod +x "$DATA_DIR/hooks/on-event"
  run python3 "$ROOT/scripts/discord-notify.py" event join "Ada Lovelace"
  [ "$status" -eq 0 ]
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$DATA_DIR/hook.out" ] && break; sleep 0.2; done
  [ "$(cat "$DATA_DIR/hook.out")" = 'join|Ada Lovelace' ]
}

@test "Discord card offers the map only when the map is on" {
  printf '{"ts":1700000000,"players":[]}' >"$CONTROL_DIR/status.json"
  body=$(SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $body != *'/map'* ]]
  body=$(WEB_MAP=true SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [ "$(jq -r '[.. | objects | select(.label == "Map")][0].url' <<<"$body")" = https://play.example/map ]
  [ "$(jq '[.. | objects | select(.type == 12)] | length' <<<"$body")" -eq 0 ]  # no still yet, no picture
  mkdir -p "$DATA_DIR/public"; printf '{"still":"abc123"}' >"$DATA_DIR/public/map.json"
  body=$(WEB_MAP=true SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [ "$(jq -r '[.. | objects | select(.type == 12)][0].items[0].media.url' <<<"$body")" = 'https://play.example/map.png?v=abc123' ]
}

@test "Discord card sends players with mods to the join page's Play with mods, never to a file the server no longer serves" {
  mkdir -p "$PUBLIC_DIR"
  printf '{"schema":3,"mods":[{"name":"A"},{"name":"B"}]}' >"$PUBLIC_DIR/mods.json"
  body=$(SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ "$body" == *'**Mods** (2)'*'**Play with mods**'*'https://play.example/join)'* ]]
  [[ "$body" != *moonpool.cmd* ]]
}

@test "turning PUBLISH_CARD off takes an earlier card.json off the web port" {
  printf '{"ts":1700000000,"world_name":"All Blue","players":[]}' >"$CONTROL_DIR/status.json"
  SN2_NOW=1700000000 PUBLISH_CARD=true python3 "$ROOT/scripts/discord-notify.py" status
  [ -f "$PUBLIC_DIR/card.json" ]
  SN2_NOW=1700000000 python3 "$ROOT/scripts/discord-notify.py" status
  [ ! -e "$PUBLIC_DIR/card.json" ]
}

@test "card.yaml rewords the card line by line; a bad line is logged and the shipped one kept" {
  printf '{"ts":1700000000,"players":[]}' >"$CONTROL_DIR/status.json"
  cat >"$DATA_DIR/card.yaml" <<'YAML'
nobody_aboard: "Empty sea for now."
tip: "-# House rule: no base griefing"
mods: "bad {evil.__class__} placeholder"
footer: 12
not_a_line: "x"
YAML
  body=$(SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ "$body" == *'Empty sea for now.'* ]]; [[ "$body" == *'House rule: no base griefing'* ]]
  [[ "$body" != *'bad '* ]]; [[ "$body" == *'Unofficial and not affiliated'* ]]
  grep -q 'card.yaml mods: placeholders here are {n}, {url}' "$LOG_DIR/discord.log"
  grep -q 'card.yaml footer: must be text' "$LOG_DIR/discord.log"
  grep -q 'card.yaml not_a_line: not a card line' "$LOG_DIR/discord.log"
}

@test "Discord card counts waiting friend requests, never names them, and drops the line at zero" {
  printf '{"count":2,"names":["Alice"]}' >"$RUN_DIR/friend-requests.json"
  body=$(python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ "$body" == *'Friend requests waiting for the host: 2'* ]]
  [[ "$body" != *Alice* ]]
  body=$(AUTO_ACCEPT_FRIENDS=1 python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ "$body" != *'Friend requests waiting'* ]]
  printf '{"count":0,"names":[]}' >"$RUN_DIR/friend-requests.json"
  body=$(python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ "$body" != *'Friend requests waiting'* ]]
}

@test "card.example.yaml lists every line the card has, and nothing else" {
  python3 - "$ROOT" <<'PY'
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("dn", root / "scripts" / "discord-notify.py"); dn = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0]]; spec.loader.exec_module(dn)
keys = [l.split(":", 1)[0] for l in (root / "card.example.yaml").read_text().splitlines() if l and not l.startswith(("#", " "))]
assert keys == list(dn.TEXT), (keys, list(dn.TEXT))
PY
}

@test "Discord card lists known player ping and omits unknown ping" {
  printf '{"ts":1700000000,"players":[{"name":"Host","ping_ms":1},{"name":"Alice","ping_ms":23},{"name":"Bob"}]}' \
    >"$CONTROL_DIR/status.json"
  body=$(SN2_NOW=1700000000 HOST_NAME=Host \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  aboard=$(jq -r '.components[0].components[] | select(.type == 10) | .content | select(startswith("**Aboard**"))' <<<"$body")
  [[ $aboard == *$'• Alice · 23 ms\n• Bob'* ]]
  [[ $aboard != *'Bob ·'* ]]

  body=$(SN2_NOW=1700000000 HOST_NAME=Host SHOW_PLAYER_NAMES=false \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  aboard=$(jq -r '.components[0].components[] | select(.type == 10) | .content | select(startswith("**Aboard**"))' <<<"$body")
  [[ $aboard == *$'• Player 1 · 23 ms\n• Player 2'* ]]
  [[ $aboard != *Alice* ]]
}

@test "Discord card converts the pinned card in place, uploads no file and publishes no map" {
  command -v python3 >/dev/null || skip "python3 not installed"
  fake_discord; map_status
  mkdir -p "$DATA_DIR/discord"; printf card-1 >"$DATA_DIR/discord/card.id"
  run env SN2_NOW=1700000000 SN2_PUBLIC_URL=https://play.example python3 "$ROOT/scripts/discord-notify.py" status
  [ "$status" -eq 0 ]
  grep -q '^PATCH .*messages/card-1?with_components=true$' "$DISCORD_CALLS"
  # The edit clears the old embed and its attachment, so the pinned message becomes the V2 card.
  grep -Fq '"embeds":null' "$DISCORD_BODIES"
  grep -Fq '"attachments":[]' "$DISCORD_BODIES"
  run ! grep -q 'map.png' "$DISCORD_BODIES"
}

@test "Discord takes its restart and outage alerts down after recovery" {
  fake_discord; map_status
  run env SN2_NOW=1700000000 python3 "$ROOT/scripts/discord-notify.py" event restart "re-hosting on Slot1"
  [ "$status" -eq 0 ]
  run env SN2_NOW=1700000010 python3 "$ROOT/scripts/discord-notify.py" event outage
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' <"$DATA_DIR/discord/alerts.ids")" = 'alert-1 alert-2 ' ]
  run env SN2_NOW=1700000030 python3 "$ROOT/scripts/discord-notify.py" event up
  [ "$status" -eq 0 ]
  grep -q '^DELETE .*messages/alert-1$' "$DISCORD_CALLS"
  grep -q '^DELETE .*messages/alert-2$' "$DISCORD_CALLS"
  run ! grep -q '^DELETE .*messages/card-1' "$DISCORD_CALLS"
  [ ! -e "$DATA_DIR/discord/alerts.ids" ]
}

@test "Discord card says Open only once the world is hosted, Starting while the game runs unhosted" {
  fake="$BATS_TEST_TMPDIR/pid-bin"; mkdir -p "$fake"
  printf '#!/usr/bin/env bash
echo 4242
' >"$fake/pgrep"; chmod +x "$fake/pgrep"
  printf '{"ts":1700000000,"world_name":"Deep Blue","players":[]}' >"$CONTROL_DIR/status.json"
  # A fresh status.json left by the last run and no readiness.json yet (the launcher removes it) is Starting, not Open.
  rm -f "$CONTROL_DIR/readiness.json"
  body=$(PATH="$fake:$PATH" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Starting**'* ]]
  printf '{"hosted":false}' >"$CONTROL_DIR/readiness.json"
  body=$(PATH="$fake:$PATH" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Starting**'* ]]
  [ "$(jq -r '.components[0].components[0].accessory.disabled' <<<"$body")" = true ]
  # Past STARTING_MAX seconds of game run time the card stops saying Starting and says nobody can join.
  printf '#!/usr/bin/env bash
echo 1500
' >"$fake/ps"; chmod +x "$fake/ps"
  body=$(PATH="$fake:$PATH" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Not hosting**'* ]]
  [ "$(jq -r '.components[0].components[0].accessory | "\(.label) \(.disabled)"' <<<"$body")" = 'Not open true' ]
  [[ $(jq -r '.components[0].components[3].content' <<<"$body") == 'The game has run for 25 min without opening its world. Nobody can join until it does.' ]]
  [[ $(jq -r '.components[0].components[4].content' <<<"$body") != *'crash report'* ]]
  # A crash dump from this run and no mods started: the card says the loader is why.
  ue="$BATS_TEST_TMPDIR/game/Subnautica2/Binaries/Win64/ue4ss"; mkdir -p "$ue"
  : >"$ue/crash_1.dmp"; printf 'Locating KismetStringLibrary...\n' >"$ue/UE4SS.log"
  body=$(PATH="$fake:$PATH" GAME_DIR="$BATS_TEST_TMPDIR/game" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[4].content' <<<"$body") == 'The mod loader wrote a crash report during this run'* ]]
  printf 'Starting mods (from enabled.txt)\n' >>"$ue/UE4SS.log"
  body=$(PATH="$fake:$PATH" GAME_DIR="$BATS_TEST_TMPDIR/game" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $body != *'crash report'* ]]
  # A hosted world whose mod has gone quiet is neither Open nor Not hosting: the card says Starting.
  printf '{"hosted":true}' >"$CONTROL_DIR/readiness.json"
  body=$(PATH="$fake:$PATH" SN2_NOW=1700000200 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Starting**'* ]]
  printf '{"hosted":false}' >"$CONTROL_DIR/readiness.json"
  body=$(PATH="$fake:$PATH" STARTING_MAX=1800 SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Starting**'* ]]
  rm "$fake/ps"
  printf '{"hosted":true}' >"$CONTROL_DIR/readiness.json"
  body=$(PATH="$fake:$PATH" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Open**'* ]]
  [ "$(jq -r '.components[0].components[0].accessory | "\(.label) \(.disabled)"' <<<"$body")" = 'Join false' ]
}

@test "a world without a webhook publishes its panel; a board shows it beside its own, and a silent world as Offline" {
  printf '{"ts":1700000000,"world_name":"All Blue","players":[]}' >"$CONTROL_DIR/status.json"
  run env SN2_NOW=1700000000 python3 "$ROOT/scripts/discord-notify.py" status
  [ "$status" -eq 0 ]
  [ ! -e "$PUBLIC_DIR/card.json" ]
  run env SN2_NOW=1700000000 PUBLISH_CARD=true python3 "$ROOT/scripts/discord-notify.py" status
  [ "$status" -eq 0 ]
  [ "$(jq -r '"\(.ts) \(.world) \(.container.type)"' "$PUBLIC_DIR/card.json")" = '1700000000 All Blue 17' ]
  fake_discord; cp "$PUBLIC_DIR/card.json" "$FAKE/peer/card.json"; peer="http://127.0.0.1:$(cat "$FAKE/port")/peer"
  printf '{"ts":1700000000,"world_name":"Midnight Zone","players":[]}' >"$CONTROL_DIR/status.json"
  body=$(SN2_NOW=1700000100 DISCORD_BOARD_PEERS="$peer/card.json $peer/missing.json" \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [ "$(jq '.components | length' <<<"$body")" -eq 4 ]
  [[ $(jq -r '.components[0] | tostring' <<<"$body") == *'Midnight Zone'* ]]
  [[ $(jq -r '.components[1] | tostring' <<<"$body") == *'All Blue'* ]]
  [[ $(jq -r '.components[2].components[0].content' <<<"$body") == *'**Offline**'* ]]
  # A panel past DISCORD_PEER_MAX_AGE is no signal too, never a stale Open.
  body=$(SN2_NOW=1700009999 DISCORD_BOARD_PEERS="$peer/card.json" \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[1].components[0].content' <<<"$body") == *'All Blue'*'**Offline**'* ]]
}

@test "Discord alerts are silent unless pushes are asked for, and mention the role as a role" {
  fake_discord; map_status
  run env SN2_NOW=1700000000 python3 "$ROOT/scripts/discord-notify.py" --dry-run event restart "maintenance"
  [ "$status" -eq 0 ]
  [[ $output == *'maintenance","flags":4096'* ]]
  run env SN2_NOW=1700000000 DISCORD_ALERTS_NOTIFY=true python3 "$ROOT/scripts/discord-notify.py" --dry-run event outage
  [ "$status" -eq 0 ]
  [[ $output == *'outage","flags":0'* ]]
  run env SN2_NOW=1700000000 DISCORD_ALERT_ROLE_ID=123 python3 "$ROOT/scripts/discord-notify.py" --dry-run event outage
  [ "$status" -eq 0 ]
  [[ $output == *'<@&123> SN2 Host: outage'* ]]
}

@test "Discord keeps an alert id whose delete failed, for the next recovery" {
  fake_discord; map_status
  run env SN2_NOW=1700000000 python3 "$ROOT/scripts/discord-notify.py" event outage
  [ "$status" -eq 0 ]
  : >"$FAKE/delete-fails"
  run env SN2_NOW=1700000030 python3 "$ROOT/scripts/discord-notify.py" event up
  [ "$status" -eq 0 ]
  [ "$(cat "$DATA_DIR/discord/alerts.ids")" = alert-1 ]
}

@test "mod stats: GitHub and CurseForge numbers reach the page escaped, and a failed read keeps the last ones" {
  api="$BATS_TEST_TMPDIR/api"; mkdir -p "$api/gh/repos/o" "$api/cf/mods"
  printf '{"stargazers_count":1234,"pushed_at":"2026-05-28T10:00:00Z","owner":{"login":"<b>o</b>"}}' >"$api/gh/repos/o/r"
  printf '{"data":{"downloadCount":27319,"dateModified":"2026-05-31T00:00:00Z","authors":[{"name":"jsthop3"}],"summary":"A <i>minimap</i>."}}' >"$api/cf/mods/42"
  cat >"$CONTROL_DIR/plugins.yaml" <<'YAML'
plugins:
  - {name: A, summary: "Does a thing.", source: "https://github.com/o/r"}
  - {name: B, install: {type: curseforge, project_id: 42, file_id: 1}}
YAML
  export GITHUB_API_URL="file://$api/gh" CURSEFORGE_API_URL="file://$api/cf" CURSEFORGE_API_KEY=k SN2_NOW=1700000000
  python3 "$ROOT/scripts/mod-stats.py" "$CONTROL_DIR/plugins.yaml" "$RUN_DIR/mod-stats.json"
  [ "$(jq -r '.mods.A.stars' "$RUN_DIR/mod-stats.json")" = 1234 ]
  [ "$(jq -r '.mods.B.downloads' "$RUN_DIR/mod-stats.json")" = 27319 ]
  out=$(python3 "$ROOT/scripts/plugins-section.py" "$CONTROL_DIR/plugins.yaml" "$PUBLIC_DIR" "$RUN_DIR/mod-stats.json")
  [[ $out == *'Does a thing.</span><span class="meta">&#9733; 1,234 on GitHub &middot; updated 28 May 2026 &middot; by &lt;b&gt;o&lt;/b&gt;'* ]]
  # B has no summary of its own: CurseForge's, escaped.
  [[ $out == *'<span class="about">A &lt;i&gt;minimap&lt;/i&gt;.</span>'* ]]
  [[ $out == *'27,319 downloads on CurseForge &middot; updated 31 May 2026 &middot; by jsthop3'* ]]
  [[ $out == *'not that its file is safe'* ]]
  # Within the refresh window nothing is read; past it, an unreachable API keeps the last numbers.
  rm "$api/gh/repos/o/r"
  SN2_NOW=1700001000 python3 "$ROOT/scripts/mod-stats.py" "$CONTROL_DIR/plugins.yaml" "$RUN_DIR/mod-stats.json"
  [ "$(jq -r '.ts' "$RUN_DIR/mod-stats.json")" = 1700000000 ]
  SN2_NOW=1700100000 python3 "$ROOT/scripts/mod-stats.py" "$CONTROL_DIR/plugins.yaml" "$RUN_DIR/mod-stats.json"
  [ "$(jq -r '.ts' "$RUN_DIR/mod-stats.json")" = 1700100000 ]
  [ "$(jq -r '.mods.A.stars' "$RUN_DIR/mod-stats.json")" = 1234 ]
  # The same name now points at another project: the old numbers are not shown beside it.
  sed -i 's#github.com/o/r#github.com/o/other#' "$CONTROL_DIR/plugins.yaml"
  SN2_NOW=1700200000 python3 "$ROOT/scripts/mod-stats.py" "$CONTROL_DIR/plugins.yaml" "$RUN_DIR/mod-stats.json"
  [ "$(jq -r '.mods.A' "$RUN_DIR/mod-stats.json")" = null ]
  # A hostile answer cannot reach the page as markup, nor break it.
  printf '{"data":{"downloadCount":5,"dateModified":"<x>-05-01","authors":[{"name":"<script>"}]}}' >"$api/cf/mods/42"
  SN2_NOW=1700300000 python3 "$ROOT/scripts/mod-stats.py" "$CONTROL_DIR/plugins.yaml" "$RUN_DIR/mod-stats.json"
  out=$(python3 "$ROOT/scripts/plugins-section.py" "$CONTROL_DIR/plugins.yaml" "$PUBLIC_DIR" "$RUN_DIR/mod-stats.json")
  [[ $out == *'5 downloads on CurseForge &middot; by &lt;script&gt;'* && $out != *'<x>'* && $out != *'<script>'* ]]
  # The key goes to CurseForge's API host only.
  CURSEFORGE_API_URL=https://evil.example/v1 SN2_NOW=1700400000 run python3 "$ROOT/scripts/mod-stats.py" "$CONTROL_DIR/plugins.yaml" "$RUN_DIR/mod-stats.json"
  [[ $output == *'refusing to send the CurseForge key to https://evil.example'* ]]
}
