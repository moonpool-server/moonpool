#!/usr/bin/env bash
# The Windows Steam client has no CLI for its beta opt-in or persona, so STEAM_BRANCH and HOST_NAME
# are written into its own VDF files while it is stopped. --report prints branch and build id.
set -u
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

manifest="$STEAM_DIR/steamapps/appmanifest_$GAME_APP_ID.acf"

if [ "${1:-}" = --report ]; then
  # version.json names the build even without a manifest; it ships as UTF-16.
  label=$(tr -d '\000\r' <"$GAME_DIR/version.json" 2>/dev/null | grep -ao '"build_server_label": *"[^"]*"' | cut -d'"' -f4)
  [ -f "$manifest" ] || { echo "no Steam manifest at $manifest; game build label=${label:-unknown}"; exit 1; }
  branch=$(vdf_get "$manifest" BetaKey)
  echo "branch=${branch:-public} buildid=$(vdf_get "$manifest" buildid) label=${label:-unknown} manifest=$manifest"
  exit 0
fi

if pgrep -f 'steam\.exe' >/dev/null; then log "steam-config: Steam is running; settings applied on next start"; exit 0; fi

case $STEAM_BRANCH in
  public | experimental) ;;
  *) log "steam-config: STEAM_BRANCH must be public or experimental, not '$STEAM_BRANCH'"; exit 64 ;;
esac
if [ -f "$manifest" ]; then
  want=$STEAM_BRANCH; [ "$want" = public ] && want=''
  have=$(vdf_get "$manifest" BetaKey)
  if [ "$have" != "$want" ]; then
    # Drop every BetaKey line, then add one under UserConfig and MountedConfig.
    sed -i -E '/^\s*"BetaKey"/d' "$manifest"
    if [ -n "$want" ]; then
      sed -i -E "s/^(\s*)\"(UserConfig|MountedConfig)\"\s*$/&/; /^\s*\"(UserConfig|MountedConfig)\"\s*$/{n;s/^(\s*)\{\s*$/&\n\1\t\"BetaKey\"\t\t\"$want\"/}" "$manifest"
    fi
    log "steam-config: branch ${have:-public} -> $STEAM_BRANCH; Steam updates the game on its next start"
  fi
elif [ "$STEAM_BRANCH" != public ]; then
  # A running client overwrites this file. Seeded before it starts as 1026 (needs update), Steam downloads this branch itself.
  mkdir -p "$(dirname "$manifest")"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"Universe"\t\t"1"\n\t"StateFlags"\t\t"1026"\n\t"installdir"\t\t"Subnautica2"\n\t"UserConfig"\n\t{\n\t\t"BetaKey"\t\t"%s"\n\t}\n\t"MountedConfig"\n\t{\n\t\t"BetaKey"\t\t"%s"\n\t}\n}\n' \
    "$GAME_APP_ID" "$STEAM_BRANCH" "$STEAM_BRANCH" >"$manifest"
  log "steam-config: branch $STEAM_BRANCH selected for the first download"
fi

name=${HOST_NAME//[\"\\]/}
# Both files carry the persona.
for cfg in "$STEAM_DIR"/config/loginusers.vdf "$STEAM_DIR"/userdata/*/config/localconfig.vdf; do
  [ -f "$cfg" ] || continue
  if grep -q '"PersonaName"' "$cfg"; then
    sed -i -E "s/(\"PersonaName\"\s*)\"[^\"]*\"/\1\"$name\"/" "$cfg"
    log "steam-config: persona set to '$name' in ${cfg#"$STEAM_DIR"/}"
  fi
done
