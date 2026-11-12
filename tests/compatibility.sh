#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Capture with the native tools on PATH, then build and execute through Nix.
# Usage: bash tests/compatibility.sh GHC-VERSION CABAL-VERSION EVIDENCE-DIR
set -euo pipefail
root=$(pwd -P)
expected_ghc=$1
expected_cabal=$2
evidence=$3
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd -P)
test "$(ghc --numeric-version)" = "$expected_ghc"
test "$(cabal --numeric-version)" = "$expected_cabal"
ghc --info > "$evidence/ghc-info.txt"
cabal --version > "$evidence/cabal-version.txt"
git rev-parse HEAD > "$evidence/revision.txt"
nix eval --impure --raw --expr builtins.currentSystem > "$evidence/system.txt"
case "$(uname -s):$(uname -m):$(cat "$evidence/system.txt")" in
  Linux:x86_64:x86_64-linux|Linux:aarch64:aarch64-linux|Darwin:arm64:aarch64-darwin) ;;
  *) echo 'Native runner and Nix system disagree' >&2; exit 1 ;;
esac
nix hash path "$root" > "$evidence/source-nar-hash.txt"
cli=$(nix build '.#cli' --no-link --print-out-paths)/bin/cabal-purifier
sources="$root#lib.caisson.libManifest.sources"
nixpkgs=$(nix eval --raw "$sources.nixpkgs.outPath")
purifier=$(nix eval --raw "$sources.purifier.outPath")
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -R tests/fixtures/app "$work/app"
chmod -R u+w "$work/app"
# Generate a new plan for this SDK; never rewrite a committed lock's compiler.
rm "$work/app/cabal-purifier.lock.json"
(cd "$work/app" && "$cli" lock)
cp "$work/app/cabal-purifier.lock.json" "$evidence/lock.json"
nix build --no-link --json --file tests/build.nix \
  --argstr src "$work/app" --argstr nixpkgs "$nixpkgs" \
  --argstr purifier "$purifier" > "$evidence/builds.json"
python3 - "$evidence" "$expected_ghc" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
builds = json.loads((root / 'builds.json').read_text())
outputs = [output for build in builds for output in build['outputs'].values()]
(root / 'outputs.json').write_bytes(subprocess.check_output(['nix', 'path-info', '--json', *outputs]))
(root / 'derivations.json').write_bytes(subprocess.check_output(
    ['nix', 'derivation', 'show', *[build['drvPath'] for build in builds]]))
assert len(outputs) == 1, builds
output = pathlib.Path(outputs[0])
plan = json.loads((output / 'plan.json').read_text())
assert plan['compiler-id'] == 'ghc-' + sys.argv[2], plan['compiler-id']
result = subprocess.check_output([str(output / 'bin/hello')], text=True)
assert result.startswith('hello purified '), result
(root / 'runtime.txt').write_text(result)
(root / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
PY
