#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Capture with the actual runner SDK, then test the installed FFI closure.
set -euo pipefail
. tests/common.sh
cd "$work/fixtures/foreign-library"
"$cli" lock
cd "$root"
sources="$root#lib.caisson.libManifest.sources"
args=(
  --file "$root/tests/native-build.nix"
  --argstr src "$work/fixtures/foreign-library"
  --argstr externalSrc "$work/fixtures/foreign-external"
  --argstr competitorSrc "$work/fixtures/foreign-library99"
  --argstr competitorExternalSrc "$work/fixtures/foreign-external99"
  --argstr nixpkgs "$(nix eval --raw "$sources.nixpkgs.outPath")"
  --argstr purifier "$(nix eval --raw "$sources.purifier.outPath")"
)
result=$(nix build --no-link --print-out-paths "${args[@]}")
nix build --no-link --rebuild "${args[@]}"
producer=$(python3 - "$result/native-products.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['selectedRoot'].split('/lib/answer/')[0])
PY
)
producerDrv=$(nix-store -q --deriver "$producer")
nix build --no-link --rebuild "$producerDrv^*"
negativeArgs=(
  --file "$root/tests/native-negative-build.nix"
  --argstr externalSrc "$work/fixtures/foreign-external"
  --argstr nixpkgs "$(nix eval --raw "$sources.nixpkgs.outPath")"
  --argstr purifier "$(nix eval --raw "$sources.purifier.outPath")"
)
if nix build --no-link "${negativeArgs[@]}" --argstr src "$work/fixtures/foreign-library" \
    --arg missingSymbol true > "$work/missing-symbol.log" 2>&1; then
  fail "native producer accepted a missing declared export"
fi
grep -qF 'native foreign library lacks declared exports' "$work/missing-symbol.log"
cp -r "$work/fixtures/foreign-library" "$work/fixtures/foreign-no-export"
python3 - "$work/fixtures/foreign-no-export/src/Answer.hs" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(''.join(line for line in p.read_text().splitlines(keepends=True) if not line.startswith('foreign export')))
PY
if nix build --no-link "${negativeArgs[@]}" --argstr src "$work/fixtures/foreign-no-export" \
    > "$work/no-export.log" 2>&1; then
  fail "native producer accepted a non-exporting shared library"
fi
grep -qF 'native foreign library lacks declared exports' "$work/no-export.log"
echo "native-products.sh: runner-native capture, C/Python/Java, transitive external closure and controls passed"
