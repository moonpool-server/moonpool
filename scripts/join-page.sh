#!/usr/bin/env bash
# One static, atomic HTML render from the game's current Steam lobby
# record; no web framework is needed or appropriate for the read-only root.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
RUN_DIR="${RUN_DIR:-$DATA_DIR/run}"
PUBLIC_DIR="${PUBLIC_DIR:-$DATA_DIR/public}"
SESSION="${SESSION_FILE:-$RUN_DIR/mod-session.json}"
mkdir -p "$PUBLIC_DIR"

esc() { printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }

world=$(esc "${WORLD_NAME:-Subnautica 2 server}")
lobby=$(jq -r '.lobby_id // empty' "$SESSION" 2>/dev/null || true)
sid=$(jq -r '.host_steamid // empty' "$SESSION" 2>/dev/null || true)
case $lobby in 0x*) lobby=$(printf '%d' "$lobby") ;; esac

# The server's mod list (control/plugins.yaml): grouped Required/Optional, each a
# link to its own page, with the "Play with mods" launcher when the publisher has
# turned the list into a signed manifest (public/mods.json). Absent or empty
# renders nothing, leaving a plain "Join now".
CONTROL_DIR="${SN2_CONTROL_DIR:-$DATA_DIR/control}"
modnote=$(python3 "$(dirname "$0")/plugins-section.py" "$CONTROL_DIR/plugins.yaml" "$PUBLIC_DIR" 2>/dev/null || true)

# The Steam branch and build the server runs, off its install manifest: a player on
# another branch cannot join, so the page says which one before they try.
manifest="${SN2_APPMANIFEST:-${WINEPREFIX:-$DATA_DIR/wine}/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_1962700.acf}"
vdf() { python3 "$(dirname "$0")/steamfile.py" "$manifest" "$1" || true; }
build=$(vdf buildid); branch=$(vdf BetaKey); branch=${branch:-${STEAM_BRANCH:-}}
buildline=''
if [ -n "$branch$build" ]; then
  b=${branch:-public}; b="$(printf '%s' "${b:0:1}" | tr '[:lower:]' '[:upper:]')${b:1}"
  buildline="<p class=\"fine\">$(esc "$b") branch${build:+ &middot; build $(esc "$build")}"
  [ "${branch:-public}" = public ] || buildline="$buildline &middot; in Steam, set Subnautica 2 &rsaquo; Properties &rsaquo; Betas to <strong>$(esc "$branch")</strong> first"
  buildline="$buildline</p>"
fi

if [[ $lobby =~ ^[0-9]+$ && $sid =~ ^[0-9]{17}$ ]]; then
  join="steam://joinlobby/1962700/$lobby/$sid"
  friend="https://steamcommunity.com/profiles/$sid"
  lead='Opening Subnautica 2 through Steam…'; btn='Join now'; refresh='<meta http-equiv="refresh" content="1;url='"$join"'">'; note='<p>If nothing happens, use the button above. First time? Tick <strong>Always allow</strong> on the browser&rsquo;s &ldquo;Open Steam?&rdquo; prompt so later joins take one click.</p>'; scr='c.onclick=function(){window.close()};setTimeout(function(){document.getElementById("lead").innerHTML="Launching Subnautica 2 &middot; you can close this tab";c.hidden=false},4000);document.addEventListener("visibilitychange",function(){if(document.hidden){window.close()}})'
  # A server with published mods never hands off by itself: joining would skip the launcher
  # that installs them, so the launcher is the one main action and the join sits under it.
  if jq -e '(.mods // []) | length > 0' "$PUBLIC_DIR/mods.json" >/dev/null 2>&1; then
    refresh=''
    action="$modnote"'<p class="fine"><a href="'"$join"'">Join without mods</a> &middot; Not friends with the host? <a href="'"$friend"'">Add them</a> first.</p>'
  else
  action='<div id="handoff"><p class="lead" id="lead">'"$lead"'</p><a class="button" href="'"$join"'">'"$btn"'</a>'"$note$modnote"'<p class="friend">Not friends with the host yet? <a href="'"$friend"'">open the host&rsquo;s Steam profile</a> and send a request first.</p><p><button class="close" id="close" type="button" hidden>Close this tab</button></p></div><script>(function(){var c=document.getElementById("close");'"$scr"'})()</script>'
  fi
else
  action='<p class="lead">The server is starting.</p><p>This page will be ready as soon as the world is open. Try again in a minute.</p>'
  refresh='<meta http-equiv="refresh" content="15">'
fi

tmp="$PUBLIC_DIR/join.html.tmp"
cat >"$tmp" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
$refresh<title>Join $world</title><style>
:root{color-scheme:dark;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#071923;color:#eaf7fb}body{margin:0;min-height:100vh;display:grid;place-items:center}.card{width:min(34rem,calc(100% - 3rem));padding:2.5rem;border:1px solid #286174;border-radius:18px;background:#0c2835;box-shadow:0 20px 60px #0008;text-align:center}h1{margin:0 0 1rem;font-size:clamp(1.8rem,6vw,2.7rem)}.lead{font-size:1.2rem}.button{display:block;margin:1.8rem auto;padding:1rem 1.4rem;border-radius:10px;background:#39b7d5;color:#04141c;font-weight:750;font-size:1.25rem;text-decoration:none}.button:hover{background:#70d5eb}.friend{margin-top:2rem;color:#b9d6df}a{color:#7bdcf2}.ghost{background:transparent;border:2px solid #39b7d5;color:#9fe4f5;font-size:1.05rem;padding:.8rem 1.2rem}.ghost:hover{background:#0e3647}.opt{margin-top:2.2rem;padding-top:1.4rem;border-top:1px solid #1d4a5a}.fine{font-size:.95rem;color:#9fb9c3;margin:.4rem 0 0}.mods{text-align:left;margin:.4rem 0 0;padding-left:1.2rem}.mods li{margin:.3rem 0;color:#cfe6ee}.close{margin-top:1.5rem;padding:.6rem 1.1rem;border:1px solid #286174;border-radius:8px;background:transparent;color:#b9d6df;font:inherit;cursor:pointer}.close:hover{color:#eaf7fb;border-color:#39b7d5}</style></head>
<body><main class="card"><h1>Join $world</h1>$buildline$action</main></body></html>
EOF
mv "$tmp" "$PUBLIC_DIR/join.html"
