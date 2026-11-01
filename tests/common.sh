# SPDX-License-Identifier: MIT
#
# Sourced by the shell tests, which run from the repository root. It sets
#
#   root     the repository root
#   cli      the cabal-purifier command the flake builds
#   work     a scratch directory, removed on exit, with a writable copy of
#            the fixtures at $work/fixtures
#
# and defines `fail` and `offline`. The lock run plans with the first GHC
# and cabal on PATH, and a CI image can bring its own, so PATH starts with
# the ones the flake locks.

root=$(pwd)
test_name=$(basename "$0")
cli=$(nix build "$root#cli" --no-link --print-out-paths)/bin/cabal-purifier
for tool in $(nix build --inputs-from "$root" 'nixpkgs#ghc' 'nixpkgs#cabal-install' --no-link --print-out-paths); do
  PATH="$tool/bin:$PATH"
done
export PATH
work=$(mktemp -d)
cleanup() {
  chmod -R u+w "$work"
  rm -rf "$work"
}
trap cleanup EXIT
cp -r "$root/tests/fixtures" "$work/fixtures"
chmod -R u+w "$work/fixtures"

fail() {
  echo "$test_name: $*" >&2
  exit 1
}

# Points every proxy at a closed port, so that any download fails.
offline() {
  export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
  export HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
  export ALL_PROXY=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 no_proxy='' NO_PROXY=''
}

# The problems that readLock of the Nix library finds in a project's
# lockfile, as Nix prints the list: `[ ]` for none.
lock_problems() {
  local src=$1 lockfile=${2:-$1/cabal-purifier.lock.json}
  nix-instantiate --eval --strict --expr \
    "(import $root/nix/lib/read-lock.nix { src = $src; lockFile = $lockfile; }).problems"
}
