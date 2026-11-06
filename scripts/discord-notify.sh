#!/usr/bin/env bash
# Discord webhooks are one curl each; no pinned tool reads this
# game's status.json or knows its Steam, Sonar, and its Steam/Sonar join paths.
# Keeps one silent card in one operator-owned channel and sends only restart, update,
# and outage alerts. Message ids and state live in $DATA_DIR/discord.
set -u
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
STATE="$DATA_DIR/discord"
mkdir -p "$STATE" "$LOG_DIR" 2>/dev/null || true
URL="${DISCORD_WEBHOOK_URL:-}"
STATUS_JSON="$CONTROL_DIR/status.json"
SILENT=4096

redact() { sed -E 's#https://(discord|discordapp)\.com/api/webhooks/[^ "?]+#<webhook>#g'; }
note() { printf '[%s] discord: %s\n' "$(date -u +%FT%TZ)" "$*" | redact >>"$LOG_DIR/discord.log" 2>/dev/null || true; }
now() { printf '%s' "${SN2_NOW:-$(date +%s)}"; }
sum() { sha256sum | cut -c1-32; }
sj() { jq -r "$1" "$STATUS_JSON" 2>/dev/null; }

send() { # METHOD SUFFIX BODY -> "code response"
  local method=$1 suffix=$2 body=$3 code wait args
  args=(-H 'Content-Type: application/json' --data "$body")
  if [ "$DRY" = 1 ]; then printf '%s %s\n%s\n' "$method" "${suffix:-/}" "$body"; return; fi
  [ -n "$URL" ] || { note "no DISCORD_WEBHOOK_URL; skipped"; echo 000; return; }
  for _ in 1 2; do
    code=$(curl -sS -o "$STATE/resp.json" -w '%{http_code}' -X "$method" "${args[@]}" "$URL$suffix" 2>/dev/null) || code=000
    [ "$code" = 429 ] || break
    wait=$(jq -r '.retry_after // 1 | floor' "$STATE/resp.json" 2>/dev/null)
    note "429; waiting ${wait}s once"; sleep "$wait"
  done
  note "$method ${suffix%%\?*} -> HTTP $code"
  printf '%s %s\n' "$code" "$(cat "$STATE/resp.json" 2>/dev/null)"
}

bot_api() { # METHOD PATH [BODY]
  local method=$1 path=$2 body=${3:-} args
  args=(-fsS -X "$method" -H "Authorization: Bot $DISCORD_BOT_TOKEN" -H 'Content-Type: application/json')
  [ -z "$body" ] || args+=(--data "$body")
  curl "${args[@]}" "${DISCORD_API_URL:-https://discord.com/api/v10}$path"
}

setup_channel() {
  local channel guild current allow deny wanted_allow=66624 wanted_deny=377957124096 topic roles role role_id
  [ -n "${DISCORD_BOT_TOKEN:-}" ] || { echo 'DISCORD_BOT_TOKEN is required for automated setup' >&2; return 64; }
  [ -n "${DISCORD_CHANNEL_ID:-}" ] || { echo 'DISCORD_CHANNEL_ID is required for automated setup' >&2; return 64; }
  channel=$(bot_api GET "/channels/$DISCORD_CHANNEL_ID") || return
  guild=$(jq -r '.guild_id // empty' <<<"$channel")
  [ -n "$guild" ] || { echo 'Discord did not return a guild for that channel' >&2; return 69; }
  current=$(jq -c --arg id "$guild" '[.permission_overwrites[]? | select(.id == $id and .type == 0)][0] // {}' <<<"$channel")
  allow=$(( $(jq -r '.allow // "0"' <<<"$current") | wanted_allow ))
  deny=$(( $(jq -r '.deny // "0"' <<<"$current") | wanted_deny ))
  if [ "$(jq -r '.allow // "0"' <<<"$current")" != "$allow" ] || [ "$(jq -r '.deny // "0"' <<<"$current")" != "$deny" ]; then
    bot_api PUT "/channels/$DISCORD_CHANNEL_ID/permissions/$guild" \
      "$(jq -cn --arg allow "$allow" --arg deny "$deny" '{type:0,allow:$allow,deny:$deny}')" >/dev/null || return
    echo 'changed channel permissions: members can read and react, but cannot send messages or create threads'
  else echo 'channel permissions already set'; fi
  topic="${WORLD_NAME:-Subnautica 2 server} status and join information · unofficial host"
  if [ "$(jq -r '.topic // empty' <<<"$channel")" != "$topic" ]; then
    bot_api PATCH "/channels/$DISCORD_CHANNEL_ID" "$(jq -cn --arg topic "$topic" '{topic:$topic}')" >/dev/null || return
    echo 'changed channel topic'
  else echo 'channel topic already set'; fi
  role_id=${DISCORD_ALERT_ROLE_ID:-}
  if [ -z "$role_id" ]; then
    roles=$(bot_api GET "/guilds/$guild/roles") || return
    role=$(jq -c '[.[] | select(.name == "Server alerts")][0] // empty' <<<"$roles")
    if [ -n "$role" ]; then role_id=$(jq -r .id <<<"$role"); echo "alert role already exists: $role_id"
    else
      role=$(bot_api POST "/guilds/$guild/roles" '{"name":"Server alerts","mentionable":true}') || return
      role_id=$(jq -r '.id // empty' <<<"$role")
      [ -n "$role_id" ] || { echo 'Discord created no alert role' >&2; return 69; }
      echo "created opt-in alert role: $role_id"
    fi
    echo "set DISCORD_ALERT_ROLE_ID=$role_id in .env to mention it on important alerts"
  else echo "using configured alert role: $role_id"; fi
}

manifests() {
  local lib
  printf '%s\n' "$STEAM_DIR/steamapps/appmanifest_$GAME_APP_ID.acf"
  sed -nE 's/^[[:space:]]*"path"[[:space:]]+"(.*)"[[:space:]]*$/\1/p' \
    "$STEAM_DIR/steamapps/libraryfolders.vdf" 2>/dev/null | sed 's#\\\\#/#g' |
    while IFS= read -r lib; do printf '%s\n' "$lib/steamapps/appmanifest_$GAME_APP_ID.acf"; done
}
manifest() { local m; while IFS= read -r m; do [ -f "$m" ] && { printf '%s' "$m"; return; }; done < <(manifests); }
vdf_val() { sed -nE "s/^[[:space:]]*\"$2\"[[:space:]]+\"([^\"]*)\".*/\1/p" "$1" 2>/dev/null | head -1; }
branch_name() {
  local m b=''; m=$(manifest); [ -z "$m" ] || b=$(vdf_val "$m" BetaKey)
  printf '%s' "${b:-${STEAM_BRANCH:-}}"
}

player_count() { jq --arg h "${HOST_NAME:-SN2 Host}" '[.players[]? | select(.name != $h)] | length' "$STATUS_JSON" 2>/dev/null || echo 0; }
players() {
  jq -r --arg h "${HOST_NAME:-SN2 Host}" --arg names "${SHOW_PLAYER_NAMES:-true}" '
    [.players[]? | select(.name != $h)] | to_entries
    | if length == 0 then "Nobody" else map(
        (if $names == "true" and (.value.name // "") != "" then .value.name else "Player \(.key + 1)" end)
        + (if (.value.ping_ms | type) == "number" then " · \(.value.ping_ms | round) ms" else "" end)
      ) | join("\n") end' "$STATUS_JSON" 2>/dev/null || echo Nobody
}

detected_state() {
  local age ts; ts=$(sj '.ts // 0'); case $ts in ''|*[!0-9]*) ts=0 ;; esac
  age=$(($(now) - ts))
  if [ -n "$(game_pid)" ]; then
    if [ "$ts" = 0 ] || [ "$age" -gt "${STATUS_MAX_AGE:-90}" ]; then echo starting
    # Open means joinable: the mod has made its Host call, not only that the game runs.
    elif [ -f "$CONTROL_DIR/readiness.json" ] && [ "$(jq -r '.hosted // false' "$CONTROL_DIR/readiness.json" 2>/dev/null)" != true ]; then echo starting
    else echo up; fi
  else echo down; fi
}
state() {
  local override expires st
  override=$(cat "$STATE/override" 2>/dev/null || true)
  expires=$(cat "$STATE/override.expires" 2>/dev/null || echo 0)
  if [ -n "$override" ] && [ "$(now)" -lt "$expires" ]; then st=$override; else st=$(detected_state); fi
  printf '%s' "$st"
}
since_for() {
  local st=$1 old since
  old=$(cat "$STATE/card.state" 2>/dev/null || true)
  since=$(cat "$STATE/card.since" 2>/dev/null || true)
  if [ "$st" != "$old" ] || [ -z "$since" ]; then since=$(now); fi
  if [ "$DRY" = 0 ]; then printf '%s' "$st" >"$STATE/card.state"; printf '%s' "$since" >"$STATE/card.since"; fi
  printf '%s' "$since"
}

# The card is a Components V2 message (flag 1<<15): one Container per world, sent
# by the webhook with ?with_components=true. A webhook no application owns may send
# only non-interactive components, so Join is a link button. Discord allows 40 components in one message; its reference
# states no text limit, so each world's text is clamped and, past the commonly cited
# 4000 characters, the other worlds' join steps are dropped first (card()).
V2=32768
build_id() { local m; m=$(manifest); [ -z "$m" ] || vdf_val "$m" buildid; }
world_name() { local w; w=$(sj '.world_name // empty'); printf '%s' "${w:-${WORLD_NAME:-Subnautica 2 server}}"; }

world_container() {
  local st since n names world sid code sonar branch build host slots url join='' map='' still='' stats tod weather scans
  st=$(state); since=$(since_for "$st"); n=$(player_count); names=$(players); world=$(world_name)
  sid=$(host_steamid); code=$(friend_code); sonar=$(sj '.sonar_code // empty')
  # The host's in-game friend code: the mod's status, else the code it kept
  # (control/sonar-code.txt, "<code> <steamid64>").
  [ -n "$sonar" ] || sonar=$(awk 'NR==1{print $1}' "$CONTROL_DIR/sonar-code.txt" 2>/dev/null)
  branch=$(branch_name); build=$(build_id); host=${HOST_NAME:-SN2 Host}
  slots=$(sj '.player_slots // empty'); case $slots in '' | *[!0-9]*) slots='' ;; esac
  url=$(public_url); [ -z "$url" ] || join="$url/join"
  [ -z "$url" ] || [ "${WEB_MAP:-false}" != true ] || map="$url/map"
  # The still, by its own signature so Discord fetches a changed one and caches an unchanged one.
  [ -z "$map" ] || still=$(jq -r '.still // empty' "$DATA_DIR/public/map.json" 2>/dev/null | tr -dc '0-9a-f')
  tod=$(sj '.time_of_day // empty'); weather=$(sj '.weather // empty')
  scans=$(sj '(.unlocks.scans // []) | if type == "array" then .[-3:] | join(", ") else empty end')
  # The server's mods, when the publisher has turned plugins.yaml into a manifest:
  # one line pointing at the launcher that installs them and joins.
  local mods=''
  if [ -n "$url" ] && [ -f "$DATA_DIR/public/mods.json" ]; then
    mods=$(jq -r --arg u "$url" '(.mods | length) as $n | select($n > 0)
      | "• **Mods** (\($n)): run [moonpool.cmd](\($u)/moonpool.cmd) once instead of Join Game; it installs them at the server'"'"'s versions and joins"' \
      "$DATA_DIR/public/mods.json" 2>/dev/null || true)
  fi
  # World history (world-stats.sh, cached 10 min); null when unknown.
  stats=$(WORLD_STATS_SAVE_DIR="$SAVE_DIR" "$(dirname "$0")/world-stats.sh" 2>/dev/null || true)
  printf '%s' "$stats" | jq -e 'type == "object"' >/dev/null 2>&1 || stats=null
  jq -cn --arg st "$st" --argjson since "$since" --arg world "$world" --argjson count "$n" \
    --arg names "$names" --arg host "$host" --arg slots "$slots" --arg sid "$sid" --arg code "$code" \
    --arg sonar "$sonar" --arg branch "$branch" --arg build "$build" --arg join "$join" \
    --arg mods "$mods" --argjson stats "$stats" --arg map "$map" --arg still "$still" --arg tod "$tod" --arg weather "$weather" --arg scans "$scans" '
    def esc: gsub("(?<c>[\\\\*_`~|>#])"; "\\\(.c)");
    def clamp($n): if length > $n then .[0:($n - 1)] + "…" else . end;
    def state_label: {up:"Open",starting:"Starting",updating:"Updating",down:"Down"}[.] // "Down";
    def icon: {up:"🟢",starting:"🟡",updating:"🟡",down:"🔴"}[.] // "🔴";
    def colour: if . == "up" then 3066993 elif . == "starting" or . == "updating" then 15105570 else 15158332 end;
    def daypart: (try (.[0:2] | tonumber) catch null) as $h
      | if $h == null then null elif $h >= 5 and $h < 12 then "Morning" elif $h >= 12 and $h < 17 then "Afternoon"
        elif $h >= 17 and $h < 21 then "Evening" else "Night" end;
    def sky: {DA_Clear:"Clear",DA_ClearGameStart:"Clear",DA_CloudyA:"Cloudy",DA_CloudyB:"Cloudy",DA_DistantStormy:"Storm nearby",
      DA_Misty:"Misty",DA_SparseClouds:"Light clouds",DA_StormA:"Storm",DA_StormB:"Storm",DA_Storm_Quick:"Storm"}[.];
    ($host | esc) as $h
    | ([ (if $branch == "" then null else ($branch[0:1] | ascii_upcase) + $branch[1:] end),
         (if $build == "" then null else "build \($build)" end) ] | map(select(. != null)) | join(" · ")) as $fine
    | ("## 🌊 \($world | esc)\n\($st | icon) **\($st | state_label)** since <t:\($since):R> · **\($count)"
       + (if $slots == "" then "" else "/\($slots)" end) + "** aboard"
       + (if $fine == "" then "" else "\n-# \($fine)" end) | clamp(260)) as $head
    | ([ ($tod | daypart), ($weather | sky) ] | map(select(. != null)) | join(" · ")) as $now
    | (if $count == 0 then "Nobody aboard right now."
          + (if ($stats.last_played // null) != null then (try " Last aboard <t:\($stats.last_played | fromdateiso8601):R>." catch "") else "" end)
       else "**Aboard**\n" + ($names | split("\n") | map("• " + esc) | join("\n")) end | clamp(400)) as $aboard
    | (if $stats == null then "" else
        ([ (if ($stats.created // null) != null then (try "Created <t:\($stats.created | fromdateiso8601):D>" catch null) else null end),
           (if ($stats.hours_played // null) != null then "Played \(($stats.hours_played * 10 | round) / 10) h" else null end),
           (if ($stats.players_seen | type) == "number" and $stats.players_seen > 0 then "Crew \($stats.players_seen)"
            elif ($stats.players_seen | type) == "array" and ($stats.players_seen | length) > 0
              then "Crew \($stats.players_seen | length)" else null end),
           (if ($stats.peak_players // null) != null then "Peak \($stats.peak_players) at once" else null end)
         ] | map(select(. != null)) | join(" · ")) end) as $statline
    | ([ ("**Steam** add **\($h)**"
           + (if $sid != "" then " ([profile](https://steamcommunity.com/profiles/\($sid)))" else "" end)
           + (if $code != "" then " · code **\($code)**" else "" end)),
         (if $sonar != "" then "**Xbox** add code **\($sonar)**" else empty end),
         (if $mods == "" then empty else $mods end)
       ] | join("\n") | clamp(420)) as $codes
    | {type:17, accent_color:($st | colour), components:(
        [ (if $join == "" then {type:10, content:$head}
           else {type:9, components:[{type:10, content:$head}],
                 accessory:{type:2, style:5, url:$join, disabled:($st != "up"),
                   label:(if $st == "up" then "Join" elif $st == "down" then "Offline" else "Starting…" end)}} end),
          {type:14, divider:true, spacing:1},
          {type:10, content:$aboard} ]
        + (if $now == "" then [] else [{type:10, content:$now}] end)
        + (if $scans == "" then [] else [{type:10, content:("Scanned lately: \($scans | esc)" | clamp(160))}] end)
        + (if $statline == "" then [] else [{type:10, content:("-# " + $statline | clamp(160))}] end)
        + [ {type:14, divider:false, spacing:2},
            {type:10, content:$codes} ]
        + (if $map == "" or $still == "" then [] else [{type:12, items:[{media:{url:"\($map).png?v=\($still)"}, description:"Where players have been"}]}] end)
        + (if $map == "" then [] else [{type:1, components:[{type:2, style:5, label:"Map", url:$map}]}] end))}'
}

# The steps to join, once under every world on the board.
how_to_join() {
  local branch accepts='an admin has to invite you first'
  branch=$(branch_name)
  [ "${AUTO_ACCEPT_FRIENDS:-1}" != 1 ] || [ "${ALLOWLIST_ONLY:-true}" != false ] || accepts='it accepts within a minute'
  jq -cn --arg branch "$branch" --arg accepts "$accepts" --arg note "${DISCORD_CARD_NOTE:-}" '
    ($branch != "" and $branch != "public") as $beta
    | { type:10, content:([ "### How to join", "**Steam**",
        (if $beta then "• Right-click **Subnautica 2** › **Properties** › **Betas** › pick **\($branch)**" else empty end),
        "• Add the world'"'"'s host as a friend with its code above; \($accepts)",
        "• Press **Join**, or **Friends** › right-click the host › **Join Game**",
        "**Xbox / PC Game Pass**",
        (if $beta then "• Join the Subnautica 2 preview in **Xbox Insider Hub**" else empty end),
        "• In the game'"'"'s **Friends** menu add the world'"'"'s Xbox code, then join the host from your in-game friends list. No Xbox code above? Ask an admin",
        "-# Tip: turn on background audio in the game'"'"'s audio settings, so voice keeps playing when you alt-tab",
        (if $note == "" then empty else $note end),
        "-# Unofficial and not affiliated with Unknown Worlds, KRAFTON or Valve"
      ] | join("\n")) }'
}

# This world's panel, for a board that shows several worlds in one message. Written
# every refresh, webhook or not, so a world without one still shows up on another's.
publish_card() { # CONTAINER WORLD
  local pub="${PUBLIC_DIR:-$DATA_DIR/public}"
  [ "$DRY" = 0 ] || return 0
  mkdir -p "$pub" 2>/dev/null || return 0
  jq -cn --argjson c "$1" --argjson ts "$(now)" --arg world "$2" '{ts:$ts, world:$world, container:$c}' \
    >"$pub/card.json.tmp" 2>/dev/null && mv "$pub/card.json.tmp" "$pub/card.json"
}

# DISCORD_BOARD_PEERS: the other worlds' card.json addresses, one panel each. A
# world that stopped answering is shown as "No signal", never as a stale "Open".
peer_containers() {
  local u key body ts world
  for u in ${DISCORD_BOARD_PEERS:-}; do
    key=$(printf '%s' "$u" | sum | cut -c1-12)
    body=$(curl -fsS -m 5 "$u" 2>/dev/null || true)
    if printf '%s' "$body" | jq -e '(.container.type == 17) and (.ts | type == "number")' >/dev/null 2>&1; then
      ts=$(jq -r '.ts' <<<"$body")
      if [ $(($(now) - ts)) -le "${DISCORD_PEER_MAX_AGE:-600}" ]; then
        [ "$DRY" = 1 ] || printf '%s' "$body" >"$STATE/peer-$key.json"
        jq -c '.container' <<<"$body"
        continue
      fi
    fi
    printf '%s' "$body" | jq -e '.container.type == 17' >/dev/null 2>&1 || body=$(cat "$STATE/peer-$key.json" 2>/dev/null || true)
    world=$(jq -r '.world // empty' <<<"$body" 2>/dev/null || true)
    ts=$(jq -r '.ts // empty' <<<"$body" 2>/dev/null || true)
    jq -cn --arg w "${world:-another world}" --arg ts "$ts" '{type:17, accent_color:15158332, components:[{type:10,
      content:("## 🌊 \($w)\n🔴 **No signal**" + (if $ts == "" then "" else " · last seen <t:\($ts):R>" end))}]}'
  done
}

card_payload() { # COMPONENTS -> the message body: no content, no embeds (V2)
  jq -cn --argjson c "$1" --argjson f "$((SILENT + V2))" '{flags:$f, allowed_mentions:{parse:[]}, components:$c}'
}

keep_id() {
  local response=$1 id; id=$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null)
  [ -z "$id" ] || { printf '%s' "$id" >"$STATE/card.id"; note "card message id $id kept in $STATE/card.id"; }
}
card() {
  local own peers comps payload body id='' out code hash
  own=$(world_container)
  publish_card "$own" "$(world_name)"
  peers=$(peer_containers | jq -sc '.')
  # Discord allows 40 components in one message: a world that would pass it is left
  # out whole and said in the log, never cut in half.
  comps=$(jq -cn --argjson own "$own" --argjson peers "$peers" '
    def n: 1 + ([(.components // [])[] | n] | add // 0) + (if .accessory then 1 else 0 end);
    reduce $peers[] as $p ([$own]; if ([.[] | n] | add) + ($p | n) <= 40 then . + [$p] else . end)')
  [ "$(jq length <<<"$comps")" -eq $((1 + $(jq length <<<"$peers"))) ] || note 'board full at 40 components; a world was left out'
  # Discord allows 4000 characters of text: the steps give way before a world does.
  comps=$(jq -c --argjson how "$(how_to_join)" 'def text: [.. | objects | select(.type == 10) | .content | length] | add // 0;
    if (map(text) | add) + ($how | text) <= 4000 then . + [$how] else . end' <<<"$comps")
  payload=$(card_payload "$comps"); hash=$(printf '%s' "$payload" | sum)
  if [ -z "$URL" ] && [ "$DRY" = 0 ]; then note 'no DISCORD_WEBHOOK_URL: panel published for a board only'; return 0; fi
  if [ "$DRY" = 0 ] && [ "$(cat "$STATE/card.sum" 2>/dev/null)" = "$hash" ]; then note 'card unchanged'; return; fi
  id=$(cat "$STATE/card.id" 2>/dev/null || cat "$STATE/status.id" 2>/dev/null || true)
  if [ -n "$id" ]; then
    # The edit also turns an older embed card into this one: its embed and map
    # attachment are cleared in the same request, so a pinned message stays pinned.
    body=$(jq -c '. + {embeds:null, attachments:[]}' <<<"$payload")
    out=$(send PATCH "/messages/$id?with_components=true" "$body"); code=${out%% *}
    case $code in
      404) note 'card was deleted; recreating it'; id='' ;;
      400) note "card edit refused: $(printf '%s' "${out#* }" | head -c 300); posting a new card (pin it)"; id='' ;;
      2*) [ "$DRY" = 1 ] || { printf '%s' "$id" >"$STATE/card.id"; note "card message id $id edited in place"; } ;;
    esac
  fi
  if [ -z "$id" ]; then
    out=$(send POST '?wait=true&with_components=true' "$payload")
    code=${out%% *}; [ "$DRY" = 1 ] || keep_id "${out#* }"
  fi
  [ "$DRY" = 1 ] && { echo "$out"; return; }
  case $code in 2*) printf '%s' "$hash" >"$STATE/card.sum" ;; esac
}

alert() {
  local kind=$1 detail=${2:-} role=${DISCORD_ALERT_ROLE_ID:-} body text out id
  case $kind in
    restart) text="${HOST_NAME:-SN2 Host}: restarting${detail:+ — $detail}"; printf updating >"$STATE/override" ;;
    update) text="${HOST_NAME:-SN2 Host}: update${detail:+ — $detail}"; printf updating >"$STATE/override" ;;
    outage|down|crash) text="${HOST_NAME:-SN2 Host}: outage${detail:+ — $detail}"; printf down >"$STATE/override" ;;
    *) note "refused: '$kind' is not an alert"; echo "not an alert: $kind" >&2; return 65 ;;
  esac
  printf '%s' "$(($(now) + 600))" >"$STATE/override.expires"
  [ -z "$role" ] || text="<@&$role> $text"
  # Alerts are silent (Discord's flag 4096: shown, no push or sound) unless the operator asks
  # for pushes: a night of maintenance restarts must not wake everyone who follows the channel
  # (five alerts can otherwise be pushed in one night).
  local flags=$SILENT
  [ "${DISCORD_ALERTS_NOTIFY:-false}" = true ] && flags=0
  body=$(jq -cn --arg text "$text" --arg role "$role" --argjson f "$flags" '
    {content:$text,flags:$f,allowed_mentions:(if $role == "" then {parse:[]} else {parse:[],roles:[$role]} end)}')
  out=$(send POST '?wait=true' "$body"); printf '%s\n' "$out"
  # Every alert posted here (restart, update, outage) is taken down once the server is
  # back up, so the channel goes back to holding only the card.
  if [ "$DRY" = 0 ]; then
    id=$(printf '%s' "${out#* }" | jq -r '.id // empty' 2>/dev/null)
    [ -z "$id" ] || printf '%s\n' "$id" >>"$STATE/alerts.ids"
  fi
}

clear_alerts() {
  local id out code keep=""
  [ -s "$STATE/alerts.ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    out=$(send DELETE "/messages/$id" ''); code=${out%% *}
    case $code in
      2* | 404) note "alert $id removed after recovery" ;;
      *) keep="$keep$id"$'\n' ;;
    esac
  done <"$STATE/alerts.ids"
  if [ -n "$keep" ]; then printf '%s' "$keep" >"$STATE/alerts.ids"; else rm -f "$STATE/alerts.ids"; fi
}

case ${1:-} in
  setup) setup_channel ;;
  status|welcome) card ;;
  event)
    shift
    [ "$DRY" = 1 ] || run_hook "$@"
    case ${1:-} in
      restart|update|outage|down|crash) alert "$1" "${*:2}"; card ;;
      up) rm -f "$STATE/override" "$STATE/override.expires"; clear_alerts; card ;;
      join|leave|backup_failed|'') note "routine event ${1:-empty}: card refresh only"; card ;;
      *) note "refused: '${1:-}' is not an event"; exit 65 ;;
    esac ;;
  heartbeat|flush-due|sweep) note "${1}: card refresh only"; card ;;
  avatar)
    [ -f "${2:-}" ] || exit 66
    [ "$DRY" = 1 ] && { echo 'PATCH / avatar'; exit; }
    body=$(base64 -w0 "$2"); send PATCH '' "{\"avatar\":\"data:image/png;base64,$body\"}" ;;
  *) echo 'usage: discord-notify.sh setup | [--dry-run] status | welcome | event <restart|update|outage|up|down|crash|join|leave|backup_failed> [detail] | heartbeat' >&2; exit 64 ;;
esac
