#!/usr/bin/env bash
# The signature must come from a key that is not on GitHub, so this runs on
# the maintainer's machine, after CI has built the draft.
# Usage: scripts/sign-release.sh v1.2.3 /path/to/private.pem
set -euo pipefail
tag=$1 key=$2 repo=moonpool-server/moonpool
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work"
gh release download "$tag" -R "$repo" -p moonpool.ps1
gh attestation verify moonpool.ps1 --repo "$repo" --signer-workflow "$repo/.github/workflows/ci.yml" --source-ref "refs/tags/$tag" >/dev/null
# What changed in the launcher since the release players have now, so nothing is signed unseen.
prev=$(gh release view -R "$repo" --json tagName -q .tagName 2>/dev/null || true)
if [ -n "$prev" ] && [ "$prev" != "$tag" ]; then
  gh release download "$prev" -R "$repo" -p moonpool.ps1 -O prev.ps1
  diff -u prev.ps1 moonpool.ps1 | sed -n '1,400p' || true
fi
read -r -p "Sign $tag with this content? [y/N] " ok
[ "$ok" = y ] || { echo "not signed"; exit 1; }
openssl dgst -sha256 -sign "$key" -out moonpool.ps1.sig moonpool.ps1
gh release upload "$tag" -R "$repo" moonpool.ps1.sig
gh release edit "$tag" -R "$repo" --draft=false --latest
echo "signed and published $tag"
