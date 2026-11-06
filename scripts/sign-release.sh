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
openssl dgst -sha256 -sign "$key" -out moonpool.ps1.sig moonpool.ps1
gh release upload "$tag" -R "$repo" moonpool.ps1.sig
gh release edit "$tag" -R "$repo" --draft=false --latest
echo "signed and published $tag"
