#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  export DATA_DIR="$BATS_TEST_TMPDIR/data"
  export RUN_DIR="$DATA_DIR/run" PUBLIC_DIR="$DATA_DIR/public"
  export CONTROL_DIR="$DATA_DIR/control" LOG_DIR="$DATA_DIR/logs" WORLD_NAME="Deep Blue"
  mkdir -p "$RUN_DIR" "$PUBLIC_DIR" "$CONTROL_DIR" "$LOG_DIR"
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
  grep -Fq 'Experimental branch &middot; build 26283380' "$PUBLIC_DIR/join.html"
  grep -Fq 'Betas to <strong>experimental</strong>' "$PUBLIC_DIR/join.html"
  printf '"AppState"\n{\n\t"buildid"\t\t"1"\n}\n' >"$m"
  STEAM_BRANCH='' SN2_APPMANIFEST="$m" python3 "$ROOT/scripts/join-page.py"
  grep -Fq 'Public branch &middot; build 1' "$PUBLIC_DIR/join.html"
  run ! grep -q 'Betas to' "$PUBLIC_DIR/join.html"
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
  printf '{"hosted":false}' >"$CONTROL_DIR/readiness.json"
  body=$(PATH="$fake:$PATH" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Starting**'* ]]
  [ "$(jq -r '.components[0].components[0].accessory.disabled' <<<"$body")" = true ]
  printf '{"hosted":true}' >"$CONTROL_DIR/readiness.json"
  body=$(PATH="$fake:$PATH" SN2_NOW=1700000010 SN2_PUBLIC_URL=https://play.example     python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[0].components[0].components[0].content' <<<"$body") == *'**Open**'* ]]
  [ "$(jq -r '.components[0].components[0].accessory | "\(.label) \(.disabled)"' <<<"$body")" = 'Join false' ]
}

@test "a world without a webhook publishes its panel; a board shows it beside its own, and a silent world as No signal" {
  printf '{"ts":1700000000,"world_name":"All Blue","players":[]}' >"$CONTROL_DIR/status.json"
  run env SN2_NOW=1700000000 python3 "$ROOT/scripts/discord-notify.py" status
  [ "$status" -eq 0 ]
  [ "$(jq -r '"\(.ts) \(.world) \(.container.type)"' "$PUBLIC_DIR/card.json")" = '1700000000 All Blue 17' ]
  fake_discord; cp "$PUBLIC_DIR/card.json" "$FAKE/peer/card.json"; peer="http://127.0.0.1:$(cat "$FAKE/port")/peer"
  printf '{"ts":1700000000,"world_name":"Midnight Zone","players":[]}' >"$CONTROL_DIR/status.json"
  body=$(SN2_NOW=1700000100 DISCORD_BOARD_PEERS="$peer/card.json $peer/missing.json" \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [ "$(jq '.components | length' <<<"$body")" -eq 4 ]
  [[ $(jq -r '.components[0] | tostring' <<<"$body") == *'Midnight Zone'* ]]
  [[ $(jq -r '.components[1] | tostring' <<<"$body") == *'All Blue'* ]]
  [[ $(jq -r '.components[2].components[0].content' <<<"$body") == *'**No signal**'* ]]
  # A panel past DISCORD_PEER_MAX_AGE is no signal too, never a stale Open.
  body=$(SN2_NOW=1700009999 DISCORD_BOARD_PEERS="$peer/card.json" \
    python3 "$ROOT/scripts/discord-notify.py" --dry-run status | grep '^{')
  [[ $(jq -r '.components[1].components[0].content' <<<"$body") == *'All Blue'*'**No signal**'* ]]
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

@test "channel setup is idempotent in intent and creates the alert role" {
  fake_discord
  run env DISCORD_BOT_TOKEN=secret DISCORD_CHANNEL_ID=22 DISCORD_API_URL="http://127.0.0.1:$(cat "$FAKE/port")" \
    python3 "$ROOT/scripts/discord-notify.py" setup
  [ "$status" -eq 0 ]
  [[ $output == *'changed channel permissions'* && $output == *'created opt-in alert role: 33'* ]]
  grep -q '^PUT .*/channels/22/permissions/11$' "$DISCORD_CALLS"
  grep -q '^PATCH .*/channels/22$' "$DISCORD_CALLS"
  run ! grep -q '/messages' "$DISCORD_CALLS"
  chmod 700 "$CONTROL_DIR"
  run env SN2_IN_CONTAINER=1 SN2_COMMON="$ROOT/scripts/common.sh" SN2_BIN="$ROOT/scripts" \
    SN2_CONTROL_DIR="$CONTROL_DIR" DISCORD_BOT_TOKEN=secret DISCORD_CHANNEL_ID=22 \
    DISCORD_API_URL="http://127.0.0.1:$(cat "$FAKE/port")" "$ROOT/bin/moonpool" discord setup
  [ "$status" -eq 0 ]
  [[ $output == *'changed channel permissions'* ]]
}
