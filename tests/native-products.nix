# SPDX-License-Identifier: MIT
{
  pkgs,
  build,
  src ? ./fixtures/foreign-library,
  externalSrc ? ./fixtures/foreign-external,
  competitorSrc ? ./fixtures/foreign-library99,
  competitorExternalSrc ? ./fixtures/foreign-external99,
}:
let
  product = import ./native/product.nix;
  args = {
    inherit src;
    externalPaths."../foreign-external" = externalSrc;
    nativeProducts.answer = product;
  };
  built = build args;
  competitor = build (
    args
    // {
      src = competitorSrc;
      lockFile = src + "/cabal-purifier.lock.json";
      externalPaths."../foreign-external" = competitorExternalSrc;
    }
  );
  rejects = [
    (product // { abi = "haskell"; })
    (product // { selector = "missing:flib:answer"; })
    (product // { selector = "purifier-foreign-proof:exe:answer"; })
    (product // { exports = [ ]; })
    (product // { exports = product.exports ++ [ "purifier_answer" ]; })
    (
      product
      // {
        runtime = product.runtime // {
          lifecycle = "automatic";
        };
      }
    )
    (
      product
      // {
        runtime = product.runtime // {
          threading = "concurrent";
        };
      }
    )
    (
      product
      // {
        runtime = product.runtime // {
          init = "purifier_term";
        };
      }
    )
    (
      product
      // {
        runtime = product.runtime // {
          term = "not_declared";
        };
      }
    )
  ];
  rejected =
    p:
    !(builtins.tryEval (build (args // { nativeProducts.answer = p; })).projections.native.drvPath)
    .success;
  defaultBuild = build (removeAttrs args [ "nativeProducts" ]);
  ghc = built.project.ghc;
in
assert builtins.all rejected rejects;
assert defaultBuild.projections == { };
assert defaultBuild.packages.purifier-foreign-proof.foreignLibraries == [ "answer" ];
assert built.packages.purifier-foreign-proof.foreignLibraries == [ "answer" ];
pkgs.runCommand "cabal-native-products-consumers"
  {
    nativeBuildInputs = [
      ghc
      pkgs.cabal-install
      pkgs.gcc
      pkgs.binutils
      pkgs.patchelf
      (pkgs.python3.withPackages (ps: [ ps.cffi ]))
      pkgs.jdk25
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    mkdir -p "$out"
    export HOME="$TMPDIR/home" PYTHONPATH=${built.projections.python-ffi}
    mkdir -p "$HOME"
    prefix=$(python3 -c 'import json;print(json.load(open("${built.projections.native}/catalog.json"))["prefix"])')
    competitor=$(python3 -c 'import json;print(json.load(open("${competitor.projections.native}/catalog.json"))["prefix"])')
    library="$prefix/lib/answer/libanswer.so"
    gcc -I "$prefix/include" -I "$prefix/include/ghc" ${./native/consumer.c} -ldl -o consumer
    timeout 25s ./consumer "$library" > "$out/c.txt" 2> "$out/c.stderr"
    timeout 25s python3 ${./native/ctypes-consumer.py} "$library" > "$out/ctypes.json" 2> "$out/ctypes.stderr"
    timeout 25s python3 ${./native/cffi-consumer.py} "$library" > "$out/cffi.json" 2> "$out/cffi.stderr"
    timeout 25s python3 ${./native/origins.py} "$prefix" > "$out/compiler-origins.json" 2> "$out/origins.stderr"
    cp ${./native/Consumer.java} Consumer.java
    javac Consumer.java
    timeout 25s java @${built.projections.java-ffi}/java.args --enable-native-access=ALL-UNNAMED Consumer "$library" > "$out/java.txt" 2> "$out/java.stderr"
    python3 ${./native/runtime-controls.py} "$prefix" "$competitor" "$out" ${pkgs.lib.getBin pkgs.stdenv.cc.libc}/bin/ldd
    for name in c ctypes cffi origins java; do test ! -s "$out/$name.stderr"; done
    cp "$prefix/native-products.json" "$out/native-products.json"
    printf '%s\n' '${toString (builtins.length rejects)} evaluation rejections; empty defaults and component lists preserved' > "$out/evaluation.txt"
  ''
