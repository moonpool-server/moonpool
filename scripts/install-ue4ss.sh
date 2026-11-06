#!/usr/bin/env bash
# Pins UE4SS by SHA-256 and lays out the loader and our mod for a
# headless host.
# Fetch UE4SS, verify it, lay it out next to the game, and add our mod.
#
# The loader is UE4SS's experimental build (release tag experimental-latest,
# asset UE4SS_v3.0.1-1188-gf885e8d2.zip), pinned by SHA-256 because the tag
# moves with every build. Its proxy dwmapi.dll sits next to the executable and
# loads ue4ss/UE4SS.dll at process start; no injector is used.
#
# Nothing derived from the game's binaries is shipped here. Build 1190 needs
# none of it. An operator running the pinned build supplies their own set in
# $DATA_DIR/ue4ss-layouts/<any name>/: the two layout inis, UE4SS-settings.ini,
# UE4SS_Signatures/ and exe.sha256, the FULL sha256 of the executable it is for.
# A pinned build with no set fails closed: the game starts without the loader.
# Anything in $DATA_DIR/ue4ss-local/ is copied last and wins.
# The native Microsoft C++ runtime for the game process is fetched by
# install-msvc-runtime.sh, also never committed.
set -euo pipefail
# shellcheck source=common.sh
. /opt/sn2/bin/common.sh

UE4SS_TAG="${UE4SS_TAG:-experimental-latest}"
UE4SS_CHANNEL="${UE4SS_CHANNEL:-auto}"

# The settings into the ue4ss folder; the two layouts there and beside the exe.
# (layout_set_for, the match by the stored full sha256, is common.sh's.)
apply_layout_set() {
  local f
  mkdir -p "$UE4SS_DIR"
  cp -f "$1/UE4SS-settings.ini" "$UE4SS_DIR/UE4SS-settings.ini"
  for f in MemberVariableLayout.ini VTableLayout.ini; do
    cp -f "$1/$f" "$UE4SS_DIR/$f"
    cp -f "$1/$f" "$WIN64_DIR/$f"
  done
  rm -rf "$UE4SS_DIR/UE4SS_Signatures"
  [ ! -d "$1/UE4SS_Signatures" ] || cp -r "$1/UE4SS_Signatures" "$UE4SS_DIR/"
}
# Apply the set for full sha256 $1, or fail closed: no layout left in the
# loader's way, a marker the launcher and the status card read, one plain line.
pick_layout() {
  local set_dir
  if set_dir=$(layout_set_for "$1"); then
    apply_layout_set "$set_dir"
    rm -f "$UE4SS_NO_LAYOUT_FILE"
    log "UE4SS layout: operator set ${set_dir##*/} (exe sha256 $1)"
    return 0
  fi
  rm -f "$UE4SS_DIR/MemberVariableLayout.ini" "$WIN64_DIR/MemberVariableLayout.ini" \
    "$UE4SS_DIR/VTableLayout.ini" "$WIN64_DIR/VTableLayout.ini"
  mkdir -p "$(dirname "$UE4SS_NO_LAYOUT_FILE")"
  echo "$1" >"$UE4SS_NO_LAYOUT_FILE"
  log "no layout set in $UE4SS_LAYOUTS for this build $1; set UE4SS_CHANNEL=auto (build 1190 needs none)"
  return 1
}

[ -d "$WIN64_DIR" ] || { log "install-ue4ss: game folder $WIN64_DIR missing"; exit 1; }
mkdir -p "$UE4SS_CACHE" "$RUN_DIR"
exe="$WIN64_DIR/$GAME_EXE_NAME"
exe_hash=$(sha256sum "$exe" | cut -d' ' -f1)

# auto: build 1190 unless the operator supplied a layout set for this exact
# executable, so a game update or the public branch still hosts instead of
# starting without the loader. Kept for the launcher.
if [ "$UE4SS_CHANNEL" = auto ]; then
  if layout_set_for "$exe_hash" >/dev/null; then
    UE4SS_CHANNEL=pinned; why="an operator layout set is for this build"
  else
    UE4SS_CHANNEL=upstream-experimental; why="no operator layout set for this build; 1190 reads UE 5.6 itself"
  fi
  log "install-ue4ss: UE4SS_CHANNEL=auto picked $UE4SS_CHANNEL ($why)"
fi
# The channel names the pinned asset and its sha256 (ue4ss_channel_select, common.sh).
read -r UE4SS_ASSET UE4SS_RELEASE_SHA256 _ < <(ue4ss_channel_select "$UE4SS_CHANNEL") \
  || { log "install-ue4ss: unknown UE4SS_CHANNEL '$UE4SS_CHANNEL' (auto, pinned or upstream-experimental)"; exit 1; }
echo "$UE4SS_CHANNEL" >"$UE4SS_CHANNEL_FILE"
UE4SS_URL="${UE4SS_URL:-https://github.com/UE4SS-RE/RE-UE4SS/releases/download/${UE4SS_TAG}/${UE4SS_ASSET}}"
UE4SS_VERSION="${UE4SS_ASSET%.zip}"
zip="$UE4SS_CACHE/$UE4SS_ASSET"

# $zip is $DATA_DIR/ue4ss/<pinned asset>: an operator's copy there is used offline. Else this
# repository's own mirror of the pinned builds (upstream's experimental-latest tag moves and
# dropped them), then upstream; either way the pinned SHA-256 is checked (fetch_pinned).
if ! fetch_pinned "${UE4SS_MIRROR:-https://github.com/moonpool-server/moonpool/releases/download/ue4ss-mirror}/$UE4SS_ASSET" "$zip" "$UE4SS_RELEASE_SHA256" \
  && ! fetch_pinned "$UE4SS_URL" "$zip" "$UE4SS_RELEASE_SHA256"; then
  log "install-ue4ss: no verified $UE4SS_ASSET; the experimental-latest tag moves, so set UE4SS_ASSET and UE4SS_RELEASE_SHA256 together"
  exit 1
fi

# The experimental archive holds dwmapi.dll at the top and the rest in ue4ss/;
# older flat archives are handled too. The proxy finds ue4ss/ beside the exe.
stage="$UE4SS_CACHE/extract"
rm -rf "$stage"
mkdir -p "$stage"
unzip -q -o "$zip" -d "$stage"
src="$stage"
[ -f "$stage/ue4ss/UE4SS.dll" ] && src="$stage/ue4ss"
[ -f "$src/UE4SS.dll" ] || { log "install-ue4ss: UE4SS.dll not found in the archive"; exit 1; }

mkdir -p "$UE4SS_DIR"
dwm=$(find "$stage" -maxdepth 2 -name dwmapi.dll | head -n1)
cp -f "$dwm" "$WIN64_DIR/dwmapi.dll"
(cd "$src" && find . -path ./dwmapi.dll -prune -o -type f -print0 \
  | while IFS= read -r -d '' f; do
      [ "$f" = "./UE4SS-settings.ini" ] && [ -f "$UE4SS_DIR/UE4SS-settings.ini" ] && continue
      mkdir -p "$UE4SS_DIR/$(dirname "$f")"
      cp -f "$f" "$UE4SS_DIR/$f"
    done)

# Settings for a headless run: no GUI console, no live viewer, quiet hooks.
settings="$UE4SS_DIR/UE4SS-settings.ini"
set_ini() {
  if grep -q "^$1 *=" "$settings"; then sed -i "s|^$1 *=.*|$1 = $2|" "$settings"
  else printf '%s = %s\n' "$1" "$2" >>"$settings"; fi
}
set_ini GuiConsoleEnabled 0
set_ini GuiConsoleVisible 0
set_ini ConsoleEnabled 0
set_ini EnableHotReloadSystem 0
# Engine version fixed, not auto-detected (blank values crashed);
# the working host runs 5.6 with the object-array cache off.
set_ini MajorVersion "${UE_MAJOR_VERSION:-5}"
set_ini MinorVersion "${UE_MINOR_VERSION:-6}"
set_ini bUseUObjectArrayCache false

# Our mod: original Lua and the operator's config.
mods="$UE4SS_DIR/Mods"
rm -rf "$mods/SN2SlotFreeHost"
mkdir -p "$mods/SN2SlotFreeHost"
cp -r "$MOD_SRC/SN2SlotFreeHost/Scripts" "$mods/SN2SlotFreeHost/"
: >"$mods/SN2SlotFreeHost/enabled.txt"
cfg="$DATA_DIR/sn2headless.json"
if [ ! -f "$cfg" ]; then
  # First start only; edit $cfg afterwards. The control directory comes from
  # the SN2_CONTROL_WIN environment variable the launcher sets.
  # The player limit is not stored here: the mod reads SN2_SESSION_LIMIT
  # (PLAYER_SLOTS + 1) from the launcher on every start.
  # WORLD_NAME reaches the Host call through SN2_WORLD_NAME, not this file.
  cp "$MOD_SRC/SN2SlotFreeHost/config.example.json" "$cfg"
fi
cp -f "$cfg" "$mods/SN2SlotFreeHost/config.json"
if [ -f "$mods/mods.txt" ] && ! grep -q '^SN2SlotFreeHost' "$mods/mods.txt"; then
  printf 'SN2SlotFreeHost : 1\n' >>"$mods/mods.txt"
fi

if ! ue4ss_needs_layout_set; then
  # upstream-experimental scans UE 5.6 itself: patterns and a layout would
  # override its own, so any left from pinned go.
  rm -rf "$UE4SS_DIR/UE4SS_Signatures" "$UE4SS_DIR/MemberVariableLayout.ini" "$UE4SS_DIR/VTableLayout.ini" \
    "$WIN64_DIR/MemberVariableLayout.ini" "$WIN64_DIR/VTableLayout.ini" "$UE4SS_NO_LAYOUT_FILE"
  log "install-ue4ss: channel $UE4SS_CHANNEL reads UE 5.6 natively; no layout set needed"
fi
# The operator's set for this exact build, or fail closed: no layout in the loader's
# way, a marker the launcher and the status card read, and one plain line.
if ue4ss_needs_layout_set && pick_layout "$exe_hash"; then
  # The set's settings replaced the file: keep the headless overrides.
  set_ini GuiConsoleEnabled 0; set_ini GuiConsoleVisible 0
  set_ini ConsoleEnabled 0; set_ini EnableHotReloadSystem 0
fi

# Other operator files, if any; these win.
if [ -n "$(ls -A "$UE4SS_LOCAL" 2>/dev/null)" ]; then
  cp -rf "$UE4SS_LOCAL"/. "$UE4SS_DIR"/
  log "install-ue4ss: applied local files from $UE4SS_LOCAL"
fi
# fetch_pinned verified the archive against the pin; name the pin here, not its local variable.
log "install-ue4ss: UE4SS $UE4SS_VERSION (channel $UE4SS_CHANNEL, sha256 $UE4SS_RELEASE_SHA256) and SN2SlotFreeHost staged in $UE4SS_DIR"
/opt/sn2/bin/install-msvc-runtime.sh
