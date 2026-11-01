#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests the language server in the offline mode, as an editor runs it: in a
# copy of the workspace fixture, `cabal-purifier env` puts its `cabal` shim
# first on PATH, and haskell-language-server checks the app's Main.hs and
# the library's module. The language server runs cabal through the shim,
# with every proxy pointed at a closed port, so any download would fail.
#
# Run it from the repository root. It needs nix, and network access to
# fetch the locked sources and the language server.
set -euo pipefail

root=$(pwd)
cli=$(nix build "$root#cli" --no-link --print-out-paths)/bin/cabal-purifier
hls=$(nix build 'nixpkgs#haskell-language-server' --no-link --print-out-paths)/bin
# The language server, like a developer's shell, finds GHC on PATH.
ghc=$(nix build 'nixpkgs#ghc' --no-link --print-out-paths)/bin
export PATH="$ghc:$PATH"
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures" "$work/fixtures"
chmod -R u+w "$work/fixtures"
export XDG_CACHE_HOME="$work/cache"

cd "$work/fixtures/workspace"
# The locked sources are fetched here, before the proxies are closed.
"$cli" cabal build all --dry-run > /dev/null
eval "$("$cli" env)"
[ "$(command -v cabal)" = "$work/fixtures/workspace/dist-newstyle/cabal-purifier/bin/cabal" ] ||
  { echo "editor.sh: cabal-purifier env did not put its shim first" >&2; exit 1; }

export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
export ALL_PROXY=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 no_proxy='' NO_PROXY=''
ghc_version=$(cabal exec -v0 -- ghc --numeric-version)
"$hls/haskell-language-server-$ghc_version" app/Main.hs greeting/src/Greeting.hs

echo "editor.sh: all passed"
