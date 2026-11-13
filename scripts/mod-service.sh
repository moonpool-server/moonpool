#!/usr/bin/env bash
# Lighttpd serves; this only writes its config, renders the join page
# and reruns the publisher, which turns control/plugins.yaml into the signed mod manifest.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

PLUGINS_FILE="${SN2_PLUGINS_FILE:-$CONTROL_DIR/plugins.yaml}"
PUBLISHER="$(dirname "$0")/publish-mods.py"
APP_MANIFEST="$STEAM_DIR/steamapps/appmanifest_${GAME_APP_ID}.acf"

# The host's own executable hash: the loader the launcher installs is allowed on
# exactly the builds the host has proven it on, and the host's is always one.
exe_sha256() {
  sha256sum "${WIN64_DIR:-}/${GAME_EXE_NAME:-}" 2>/dev/null | cut -d' ' -f1 || true
}

publisher() {
  UE4SS_CHANNEL_IN_FORCE="$(ue4ss_channel 2>/dev/null || echo pinned)" \
    python3 "$PUBLISHER" --data-dir "$DATA_DIR" --plugins "$PLUGINS_FILE" \
      --appmanifest "$APP_MANIFEST" --exe-sha256 "$(exe_sha256)" --ue4ss-cache "${UE4SS_CACHE:-$DATA_DIR/ue4ss}" \
      --branch "${STEAM_BRANCH:-public}" --public-url "$(public_url)" --server-name "${WORLD_NAME:-${HOST_NAME:-SN2 Host}}" "$@"
}

case ${1:-serve} in
  publish) publisher publish ;;
  pin | enable | disable) publisher "$@" ;;
  serve)
    mkdir -p "$DATA_DIR/public" "$RUN_DIR"
    python3 "$(dirname "$0")/join-page.py" || true
    cat >"$RUN_DIR/lighttpd-web.conf" <<EOF
server.document-root = "$DATA_DIR/public"
server.bind = "0.0.0.0"
server.port = ${SN2_MODS_PORT:-8081}
server.dir-listing = "disable"
server.modules = ( "mod_redirect" )
url.redirect = ( "^/$" => "/join.html", "^/join$" => "/join.html", "^/map$" => "/map.html" )
mimetype.assign = ( ".html" => "text/html; charset=utf-8", ".json" => "application/json", ".sig" => "application/octet-stream", ".zip" => "application/zip", ".png" => "image/png",
  ".css" => "text/css; charset=utf-8", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".webp" => "image/webp", ".gif" => "image/gif" )
EOF
    lighttpd -D -f "$RUN_DIR/lighttpd-web.conf" >>"$LOG_DIR/web.log" 2>&1 & http_pid=$!
    trap 'kill "$http_pid" 2>/dev/null || true' EXIT
    # The manifest follows plugins.yaml and the live lobby: republished every 30 s,
    # the join page re-rendered after it so its mod section matches.
    while kill -0 "$http_pid" 2>/dev/null; do
      if publisher --cached publish >"$RUN_DIR/mod-publish.json.tmp" 2>>"$LOG_DIR/web.log"; then :; fi
      mv -f "$RUN_DIR/mod-publish.json.tmp" "$RUN_DIR/mod-publish.json" 2>/dev/null || true
      python3 "$(dirname "$0")/join-page.py" 2>>"$LOG_DIR/web.log" || true
      sleep 30
    done
    ;;
  *) echo "usage: mod-service.sh [serve|publish|pin <name> <archive>|enable <name>|disable <name>]" >&2; exit 64 ;;
esac
