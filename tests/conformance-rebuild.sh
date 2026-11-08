#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-rebuild: `nix build --rebuild` of the app fixture's project
# build gives the same output as the first build.
#
# Run it from the repository root. It needs nix.
set -euo pipefail
. tests/common.sh

sources="$root#lib.caisson.libManifest.sources"
args=(
  --file "$root/tests/build.nix"
  --argstr src "$root/tests/fixtures/app"
  --argstr nixpkgs "$(nix eval --raw "$sources.nixpkgs.outPath")"
  --argstr purifier "$(nix eval --raw "$sources.purifier.outPath")"
)
nix build --no-link "${args[@]}"
nix build --no-link --rebuild "${args[@]}"

if [ "$(uname -s)" = Linux ]; then
  bash "$root/tests/native-products.sh"
fi

echo "conformance-rebuild.sh: all passed"
