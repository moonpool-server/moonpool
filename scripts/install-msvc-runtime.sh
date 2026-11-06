#!/usr/bin/env bash
# Fetch Microsoft's C++ runtime and place seven of its DLLs in the game folder.
#
# Why: under Wine's builtin C++ runtime the UE4SS loader stalled right after finding
# FName::FName. The files go next to the game executable and the launcher sets the
# native override on the game's command alone, so Steam and Wine keep their builtins.
# Source: Microsoft's permanent link for the x64 redistributable, pinned by SHA-256,
# downloaded into your volume at install time. NATIVE_MSVC=0 skips it and removes the files.
set -euo pipefail
# shellcheck source=common.sh
. /opt/sn2/bin/common.sh

VCREDIST_URL="${VCREDIST_URL:-https://aka.ms/vs/17/release/vc_redist.x64.exe}"
VCREDIST_SHA256="${VCREDIST_SHA256:-cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b}"
cache="$DATA_DIR/msvc"
exe="$cache/vc_redist.x64.exe"

if [ "$NATIVE_MSVC" != "1" ]; then
  for d in $MSVC_DLLS; do rm -f "$WIN64_DIR/$d"; done
  log "install-msvc-runtime: NATIVE_MSVC=$NATIVE_MSVC; game uses Wine's builtin C++ runtime"
  exit 0
fi
[ -d "$WIN64_DIR" ] || { log "install-msvc-runtime: game folder $WIN64_DIR missing"; exit 1; }
mkdir -p "$cache"

if [ ! -f "$exe" ]; then
  log "install-msvc-runtime: downloading $VCREDIST_URL"
  curl -fsSL -o "$exe.part" "$VCREDIST_URL"
  mv -f "$exe.part" "$exe"
fi
actual=$(sha256sum "$exe" | cut -d' ' -f1)
if [ "$actual" != "$VCREDIST_SHA256" ]; then
  log "install-msvc-runtime: SHA-256 mismatch: got $actual, expected $VCREDIST_SHA256; refusing"
  log "install-msvc-runtime: Microsoft updates this link; set VCREDIST_SHA256 after checking the new file's signature"
  rm -f "$exe"
  exit 1
fi

# The redistributable is a WiX bundle: 7-Zip's raw mode (-t#) splits out its
# attached cabinets, those hold the runtime packages, and their cabinets hold
# each DLL as <name>_amd64.
stage="$cache/extract"
rm -rf "$stage"
mkdir -p "$stage/bundle" "$stage/packages" "$stage/files"
7z x -y -bd -t# -o"$stage/bundle" "$exe" >/dev/null
for c in "$stage"/bundle/*.cab; do
  7z x -y -bd -o"$stage/packages" "$c" >/dev/null 2>&1 || true
done
for c in "$stage"/packages/*; do
  7z x -y -bd -o"$stage/files" "$c" >/dev/null 2>&1 || true
done
missing=""
for d in $MSVC_DLLS; do
  src=$(find "$stage/files" -type f \( -iname "${d}_amd64" -o -iname "${d%.dll}_amd64.dll" \) | head -n1)
  if [ -n "$src" ]; then cp -f "$src" "$WIN64_DIR/$d"; else missing="$missing $d"; fi
done
rm -rf "$stage"
if [ -n "$missing" ]; then
  log "install-msvc-runtime: not found in the redistributable:$missing"
  exit 1
fi
log "install-msvc-runtime: placed in the game folder: $MSVC_DLLS"
