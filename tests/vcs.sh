#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests source repositories other than git: it serves a package from a
# local Mercurial repository (`hg serve`), one from a tagged Darcs
# repository and one from an untagged Darcs repository (both over HTTP),
# locks a project that takes all three as `source-repository-package`, and
# builds and runs the project with Nix. The untagged Darcs repository is
# locked by its Darcs context.
#
# Nix fetches the checkouts through the Nix daemon, which has to reach the
# servers on 127.0.0.1, as it does on a CI runner. Run it from the
# repository root.
set -euo pipefail

root=$(pwd)
cli=$(nix build "$root#cli" --no-link --print-out-paths)/bin/cabal-purifier
hg_bin=$(nix build 'nixpkgs#mercurial^out' --no-link --print-out-paths)/bin
darcs_bin=$(nix build 'nixpkgs#darcs^out' --no-link --print-out-paths)/bin
export PATH="$hg_bin:$darcs_bin:$PATH"
# The lock run plans with the first GHC and cabal on PATH, and a CI image
# can bring its own, so the test puts the ones the flake locks first.
for tool in $(nix build --inputs-from "$root" 'nixpkgs#ghc' 'nixpkgs#cabal-install' --no-link --print-out-paths); do
  PATH="$tool/bin:$PATH"
done
export PATH
work=$(mktemp -d)
trap 'kill ${hg_server:-} ${http_server:-} 2>/dev/null || true; rm -rf "$work"' EXIT

fail() {
  echo "vcs.sh: $*" >&2
  exit 1
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# A package whose module names where it came from.
package() {
  local dir=$1 name=$2 module=$3 source=$4
  mkdir -p "$dir"
  cat > "$dir/$name.cabal" <<EOF
cabal-version: 3.0
name: $name
version: 0.1.0
build-type: Simple

library
  exposed-modules: $module
  build-depends: base
  default-language: Haskell2010
EOF
  cat > "$dir/$module.hs" <<EOF
module $module (source) where

source :: String
source = "$source"
EOF
}

echo "== serving Mercurial and Darcs repositories"
package "$work/hg" hgdemo HgDemo mercurial
(cd "$work/hg" && hg init . && hg add -q && hg commit -q -u tester -m init)
hg_rev=$(cd "$work/hg" && hg id -i)
hg_port=$(free_port)
(cd "$work/hg" && exec hg serve -a 127.0.0.1 -p "$hg_port") &
hg_server=$!

package "$work/http/tagged" darcstagged DarcsTagged "a darcs tag"
(
  cd "$work/http/tagged"
  darcs init -q
  darcs record -q -a -l -A tester -m init
  darcs tag -q -A tester v1
)
package "$work/http/untagged" darcsuntagged DarcsUntagged "a darcs context"
(
  cd "$work/http/untagged"
  darcs init -q
  darcs record -q -a -l -A tester -m init
)
http_port=$(free_port)
(cd "$work/http" && exec python3 -m http.server --bind 127.0.0.1 "$http_port") &
http_server=$!
sleep 2

echo "== locking a project with the source repositories"
mkdir -p "$work/project"
cat > "$work/project/cabal.project" <<EOF
packages: .

source-repository-package
  type: mercurial
  location: http://127.0.0.1:$hg_port/
  tag: $hg_rev

source-repository-package
  type: darcs
  location: http://127.0.0.1:$http_port/tagged
  tag: v1

source-repository-package
  type: darcs
  location: http://127.0.0.1:$http_port/untagged
EOF
cat > "$work/project/vcs.cabal" <<EOF
cabal-version: 3.0
name: vcs
version: 0.1.0
build-type: Simple

executable vcs
  main-is: Main.hs
  build-depends: base, hgdemo, darcstagged, darcsuntagged
  default-language: Haskell2010
EOF
cat > "$work/project/Main.hs" <<EOF
import qualified DarcsTagged
import qualified DarcsUntagged
import qualified HgDemo

main :: IO ()
main = putStrLn (HgDemo.source ++ ", " ++ DarcsTagged.source ++ ", " ++ DarcsUntagged.source)
EOF
(cd "$work/project" && "$cli" lock)
python3 - "$work/project/cabal-purifier.lock.json" <<'EOF'
import json
import sys

lock = json.load(open(sys.argv[1]))
darcs = [d["darcs"] for d in lock["downloads"] if "darcs" in d]
assert any(d["rev"] == "v1" and d["context"] is None for d in darcs), darcs
assert any(d["rev"] is None and d["context"] for d in darcs), darcs
EOF

echo "== building the project with Nix"
# The build takes the nixpkgs and the purifier library that the flake locks.
sources="$root#lib.caisson.libManifest.sources"
nixpkgs=$(nix eval --raw "$sources.nixpkgs.outPath")
purifier=$(nix eval --raw "$sources.purifier.outPath")
built=$(nix-build --no-out-link "$root/tests/build.nix" --argstr src "$work/project" \
  --argstr nixpkgs "$nixpkgs" --argstr purifier "$purifier")
output=$("$built/bin/vcs")
echo "$output"
[ "$output" = "mercurial, a darcs tag, a darcs context" ] || fail "the project printed $output"

echo "vcs.sh: all passed"
