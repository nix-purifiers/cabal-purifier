#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests the commands outside the Nix sandbox, in copies of the fixtures,
# beyond the conformance tests (tests/conformance-*.sh):
#
# - A lockfile older than the project makes `prefetch` and the `cabal`
#   shim stop with a message that names `cabal-purifier lock`.
# - Adding a dependency and locking keeps the index state of the last
#   lock, and the shim then builds the project offline.
# - A malformed, incomplete or tampered lockfile gives an error that says
#   what is wrong and names `cabal-purifier lock`.
# - `cabal-purifier publish` uploads the source and documentation tarballs
#   that Nix built to a stand-in Hackage (tests/fake_hackage.py), byte for
#   byte.
#
# Run it from the repository root. It needs nix and network access to
# Hackage and GitHub.
set -euo pipefail
. tests/common.sh
server=
trap 'kill "$server" 2>/dev/null || true; cleanup' EXIT

# Runs a command in a directory, which must fail with a message that holds
# `expected` and names `cabal-purifier lock`.
expect_failure() {
  local dir=$1 expected=$2 message
  shift 2
  if message=$(cd "$dir" && "$@" 2>&1); then
    fail "$* succeeded in $dir"
  fi
  case "$message" in
    *"$expected"*"cabal-purifier lock"*) ;;
    *) fail "the error in $dir did not say $expected and name cabal-purifier lock: $message" ;;
  esac
}

echo "== a stale lockfile stops prefetch and the shim"
cp -r "$work/fixtures/app" "$work/stale"
(cd "$work/stale" && eval "$("$cli" prefetch)" && cabal --numeric-version > /dev/null)
echo "-- changed" >> "$work/stale/hello.cabal"
expect_failure "$work/stale" "hello.cabal changed since the lock" "$cli" prefetch
expect_failure "$work/stale" "hello.cabal changed since the lock" \
  "$work/stale/dist-newstyle/cabal-purifier/bin/cabal" build

echo "== adding a dependency and locking keeps the index state"
cp -r "$work/fixtures/app" "$work/added"
sed -i 's/build-depends: base, random, async/build-depends: base, random, async, containers/' \
  "$work/added/hello.cabal"
(cd "$work/added" && "$cli" lock)
python3 - "$work/fixtures/app/cabal-purifier.lock.json" "$work/added/cabal-purifier.lock.json" <<'EOF'
import json
import sys

before, after = (json.load(open(p)) for p in sys.argv[1:])
assert before["indexState"] == after["indexState"], (before["indexState"], after["indexState"])
assert before["definition"]["hello.cabal"] != after["definition"]["hello.cabal"]
EOF
(
  cd "$work/added"
  eval "$("$cli" prefetch)"
  offline
  cabal build hello > /dev/null
)

echo "== a damaged lockfile gives an error that names the fix"
cp -r "$work/fixtures/app" "$work/malformed"
echo '{ "version": 2, ' > "$work/malformed/cabal-purifier.lock.json"
expect_failure "$work/malformed" "is not valid JSON" "$cli" prefetch

cp -r "$work/fixtures/app" "$work/missing"
python3 - "$work/missing/cabal-purifier.lock.json" "$root/bin/cabal-purifier" <<'EOF'
import importlib.machinery
import importlib.util
import json
import sys

loader = importlib.machinery.SourceFileLoader("cabal_purifier", sys.argv[2])
spec = importlib.util.spec_from_loader("cabal_purifier", loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)
path = sys.argv[1]
lock = json.load(open(path))
lock["downloads"] = [d for d in lock["downloads"] if d["path"] != "repository/random-1.3.1.tar.gz"]
lock["hash"] = cli.content_hash(lock)
json.dump(lock, open(path, "w"))
EOF
expect_failure "$work/missing" "uses random-1.3.1, which no locked source provides" "$cli" prefetch

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
expect_failure "$work/tampered" "does not match its hash" "$cli" prefetch

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
