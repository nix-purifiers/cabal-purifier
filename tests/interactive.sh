#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests what runs outside the Nix sandbox, in copies of the fixtures:
#
# - `cabal-purifier relock` reproduces each committed lockfile. The
#   fixtures pin Hackage's index with `index-state`, so a relock resolves
#   to the same plan.
# - `cabal-purifier cabal run` builds and runs the workspace offline from
#   the locked sources, with every proxy pointed at a closed port, so any
#   download would fail.
# - A lockfile that no longer matches the project makes `cabal-purifier
#   cabal` warn and run cabal the usual way.
# - `cabal-purifier publish` uploads the source and documentation tarballs
#   that Nix built to a stand-in Hackage (tests/fake_hackage.py), byte for
#   byte.
#
# Run it from the repository root. It needs nix and network access to
# Hackage and GitHub.
set -euo pipefail

root=$(pwd)
cli=$(nix build "$root#cli" --no-link --print-out-paths)/bin/cabal-purifier
work=$(mktemp -d)
trap 'kill "${server:-}" 2>/dev/null || true; chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures" "$work/fixtures"
chmod -R u+w "$work/fixtures"

fail() {
  echo "interactive.sh: $*" >&2
  exit 1
}

echo "== relock reproduces the committed lockfiles"
for fixture in app workspace; do
  (cd "$work/fixtures/$fixture" && "$cli" relock)
  if ! diff -u "$root/tests/fixtures/$fixture/cabal-purifier.lock.json" \
    "$work/fixtures/$fixture/cabal-purifier.lock.json"; then
    fail "relocking $fixture changed its lockfile"
  fi
done

echo "== cabal runs the workspace offline"
output=$(
  cd "$work/fixtures/workspace"
  http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    ALL_PROXY=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 no_proxy='' NO_PROXY='' \
    "$cli" cabal run greet
)
echo "$output"
case "$output" in
  *"hello workspace"*) ;;
  *) fail "cabal run greet printed no greeting" ;;
esac
(cd "$work/fixtures/workspace" && "$cli" cabal test greeting) | tee "$work/test.log"
grep -q "spec passed" "$work/test.log" || fail "cabal test greeting did not run the spec"
[ -L "$work/fixtures/workspace/dist-newstyle/cabal-purifier/sources" ] ||
  fail "cabal left no GC root for the locked sources"

echo "== a stale lock falls back to cabal with a warning"
cp -r "$work/fixtures/app" "$work/stale"
echo "-- changed" >> "$work/stale/hello.cabal"
warning=$(cd "$work/stale" && "$cli" cabal --numeric-version 2>&1 >/dev/null)
case "$warning" in
  *"hello.cabal changed since the lock"*) ;;
  *) fail "a stale lock gave no warning: $warning" ;;
esac

echo "== a damaged lockfile gives an error that names the fix"
expect_failure() {
  local dir=$1 expected=$2 message
  if message=$(cd "$dir" && "$cli" cabal build 2>&1); then
    fail "cabal build succeeded with a damaged lockfile in $dir"
  fi
  case "$message" in
    *"$expected"*"cabal-purifier relock"*) ;;
    *) fail "the error for $dir did not say $expected and name relock: $message" ;;
  esac
}
cp -r "$work/fixtures/app" "$work/malformed"
echo '{ "version": 1, ' > "$work/malformed/cabal-purifier.lock.json"
expect_failure "$work/malformed" "is not valid JSON"

cp -r "$work/fixtures/app" "$work/missing"
python3 - "$work/missing/cabal-purifier.lock.json" <<'EOF'
import json
import sys

path = sys.argv[1]
lock = json.load(open(path))
lock["downloads"] = [d for d in lock["downloads"] if d["path"] != "repository/random-1.3.1.tar.gz"]
json.dump(lock, open(path, "w"))
EOF
expect_failure "$work/missing" "names no download repository/random-1.3.1.tar.gz"

cp -r "$work/fixtures/app" "$work/tampered"
python3 - "$work/tampered/cabal-purifier.lock.json" <<'EOF'
import json
import sys

path = sys.argv[1]
lock = json.load(open(path))
for download in lock["downloads"]:
    if download["path"] == "repository/random-1.3.1.tar.gz":
        download["hash"] = "sha256-" + "A" * 43 + "="
json.dump(lock, open(path, "w"))
EOF
expect_failure "$work/tampered" "hash mismatch means"

echo "== publish uploads the tarballs Nix built"
python3 "$root/tests/fake_hackage.py" "$work/port" "$work/uploads" &
server=$!
for _ in $(seq 50); do
  [ -s "$work/port" ] && break
  sleep 0.1
done
port=$(cat "$work/port")
export CABAL_DIR="$work/upload-cabal"
mkdir -p "$CABAL_DIR"
cat > "$CABAL_DIR/config" <<EOF
repository stand-in
  url: http://127.0.0.1:$port/
  secure: False
EOF
(
  cd "$work/fixtures/workspace"
  "$cli" publish greeting --username tester --password secret
  "$cli" publish greeting --documentation --username tester --password secret
) 2>&1 | tee "$work/publish.log"
unset CABAL_DIR
# publish names the file it uploads, which is the tarball in the store.
sdist=$(sed -n 's/^cabal-purifier: uploading \(.*greeting-0\.2\.0\.tar\.gz\)$/\1/p' "$work/publish.log")
[ -n "$sdist" ] || fail "publish named no source tarball"
python3 - "$work/uploads" "$sdist" <<'EOF'
import sys
from pathlib import Path

uploads, tarball = Path(sys.argv[1]), Path(sys.argv[2]).read_bytes()
bodies = {p.name: p.read_bytes() for p in uploads.iterdir()}
candidates = [b for name, b in bodies.items() if name.startswith("POST_packages_candidates")]
if not candidates or tarball not in candidates[0]:
    sys.exit("interactive.sh: the uploaded candidate is not the tarball Nix built")
docs = [name for name in bodies if name.startswith("PUT_package_greeting-0.2.0")]
if not docs:
    sys.exit("interactive.sh: no documentation was uploaded")
print("uploads:", ", ".join(sorted(bodies)))
EOF

echo "interactive.sh: all passed"
