#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-relock: `cabal-purifier lock` in a copy of each fixture, and
# of ShellCheck v0.11.0, reproduces the committed lockfile byte for byte.
# The fixtures pin Hackage's index with `index-state`; ShellCheck pins
# none, so the lock plans with the index state its lockfile records. The
# external fixture and ShellCheck write their lockfiles outside the
# project, through --lockfile.
#
# Run it from the repository root. It needs nix and network access to
# Hackage and GitHub.
set -euo pipefail
. tests/common.sh

relocks() {
  local dir=$1 committed=$2 written=$3
  shift 3
  (cd "$dir" && "$cli" lock "$@")
  diff -u "$committed" "$written" || fail "relocking $dir changed its lockfile"
}

for fixture in app workspace; do
  relocks "$work/fixtures/$fixture" "$root/tests/fixtures/$fixture/cabal-purifier.lock.json" \
    "$work/fixtures/$fixture/cabal-purifier.lock.json"
done

mkdir -p "$work/external"
cp "$root/tests/external/cabal-purifier.lock.json" "$root/tests/external/cabal.project.freeze" "$work/external/"
relocks "$work/fixtures/external" "$root/tests/external/cabal-purifier.lock.json" \
  "$work/external/cabal-purifier.lock.json" \
  --lockfile "$work/external/cabal-purifier.lock.json" \
  --tool-lockfile "$work/external/cabal.project.freeze"
diff -u "$root/tests/fixtures/external/cabal.project.freeze" \
  "$work/fixtures/external/cabal.project.freeze" ||
  fail "locking the external fixture changed the freeze file in its tree"

rev=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["nodes"]["shellcheck"]["locked"]["rev"])' \
  "$root/tests/dependencies/flake.lock")
shellcheck=$(nix flake prefetch --json "github:koalaman/shellcheck/$rev" |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["storePath"])')
cp -r "$shellcheck" "$work/shellcheck"
chmod -R u+w "$work/shellcheck"
mkdir -p "$work/shellcheck-lock"
cp "$root/tests/real-world/shellcheck/cabal-purifier.lock.json" "$work/shellcheck-lock/"
relocks "$work/shellcheck" "$root/tests/real-world/shellcheck/cabal-purifier.lock.json" \
  "$work/shellcheck-lock/cabal-purifier.lock.json" --lockfile "$work/shellcheck-lock/cabal-purifier.lock.json"

echo "conformance-relock.sh: all passed"
