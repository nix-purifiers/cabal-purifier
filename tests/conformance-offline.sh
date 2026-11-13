#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-offline: after `cabal-purifier prefetch` in a copy of the
# workspace fixture, the everyday loop and the editor work with every
# proxy pointed at a closed port, so any download would fail. Plain
# `cabal run` and `cabal test` go through the shim that prefetch puts
# first on PATH, and haskell-language-server, from the toolchain prefetch
# realized, checks the app's Main.hs and the library's module.
#
# Run it from the repository root. It needs nix, and network access for
# the prefetch.
set -euo pipefail
. tests/common.sh

cd "$work/fixtures/workspace"
eval "$("$cli" prefetch --with-toolchain)"
[ "$(command -v cabal)" = "$PWD/dist-newstyle/cabal-purifier/bin/cabal" ] ||
  fail "prefetch did not put its cabal shim first on PATH"
[ -L cabal-purifier.lock.prefetch ] || fail "prefetch left no GC root beside the lockfile"
command -v haskell-language-server > /dev/null || fail "prefetch put no haskell-language-server on PATH"

offline
output=$(cabal run greet)
echo "$output"
case "$output" in
  *"hello workspace"*) ;;
  *) fail "cabal run greet printed no greeting" ;;
esac
cabal test greeting | tee "$work/test.log"
grep -q "spec passed" "$work/test.log" || fail "cabal test greeting did not run the spec"
haskell-language-server app/Main.hs greeting/src/Greeting.hs

echo "conformance-offline.sh: all passed"
