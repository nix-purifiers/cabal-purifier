#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-update: in a copy of the update fixture, whose freeze file
# pins async 2.2.4, `cabal-purifier update async` writes the freeze file
# again with the newest package index and locks the result. Afterwards the
# freeze file pins a newer async, the purifier lockfile plans that same
# async, and readLock finds no problem with either file: the lockfile
# records the new freeze file among the project files it was made from.
#
# Run it from the repository root. It needs nix and network access to
# Hackage.
set -euo pipefail
. tests/common.sh

dir="$work/fixtures/update"
(cd "$dir" && "$cli" update async)
cat "$dir/cabal.project.freeze"
python3 - "$dir" <<'EOF'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
freeze = (root / "cabal.project.freeze").read_text()
pinned = re.search(r"any\.async ==([0-9.]+)", freeze)
assert pinned, "the freeze file pins no async"
assert pinned.group(1) != "2.2.4", "update kept async 2.2.4"
lock = json.loads((root / "cabal-purifier.lock.json").read_text())
assert "cabal.project.freeze" in lock["definition"], lock["definition"]
for system, plan in lock["systems"].items():
    versions = {u["version"] for u in plan["units"] if u["name"] == "async"}
    assert versions == {pinned.group(1)}, (system, versions)
print("async", pinned.group(1))
EOF
problems=$(lock_problems "$dir")
[ "$problems" = "[ ]" ] || fail "the updated lockfiles have problems: $problems"

echo "conformance-update.sh: all passed"
