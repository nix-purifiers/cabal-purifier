# SPDX-License-Identifier: MIT
{
  lib,
  stdenv,
  runCommand,
  writeText,
  python3,
  cabal-install,
  binutils,
  patchelf,
  purifier,
}:
{
  name,
  nativeProducts,
  system,
  ghc',
  repository,
  constraints,
  units,
  cabalArgs,
  filteredSrc,
  projectDir,
  externalPaths,
  cabalFreeze,
  outputs,
  nativeBuildInputs,
  buildInputs,
  requiredExternalPaths,
}:
let
  keys = builtins.attrNames nativeProducts;
  symbol = s: builtins.isString s && builtins.match "[A-Za-z_][A-Za-z0-9_]*" s != null;
  valid =
    product:
    builtins.isAttrs product
    &&
      builtins.attrNames product == [
        "abi"
        "exports"
        "runtime"
        "selector"
      ]
    && product.abi == "c"
    && builtins.isString product.selector
    && builtins.isList product.exports
    && product.exports != [ ]
    && builtins.all symbol product.exports
    && lib.unique product.exports == product.exports
    && builtins.isAttrs product.runtime
    &&
      builtins.attrNames product.runtime == [
        "init"
        "kind"
        "lifecycle"
        "term"
        "threading"
      ]
    && product.runtime.kind == "ghc"
    && product.runtime.lifecycle == "process-once"
    && product.runtime.threading == "single-foreign-thread"
    && symbol product.runtime.init
    && symbol product.runtime.term
    && product.runtime.init != product.runtime.term
    && builtins.elem product.runtime.init product.exports
    && builtins.elem product.runtime.term product.exports
    && builtins.any (
      pkg: builtins.any (flib: product.selector == "${pkg}:flib:${flib}") outputs.${pkg}.foreignLibraries
    ) (builtins.attrNames outputs);
  selected =
    builtins.isAttrs nativeProducts
    && builtins.length keys == 1
    && builtins.match "[A-Za-z_][A-Za-z0-9_-]*" (builtins.head keys) != null
    && valid nativeProducts.${builtins.head keys};
  spec = writeText "cabal-native-products.json" (
    builtins.toJSON {
      products = nativeProducts;
      inherit system;
      compiler = {
        path = toString ghc';
        version = ghc'.version;
      };
      storeDir = builtins.storeDir;
    }
  );
  producer =
    runCommand "${name}-native-products"
      {
        nativeBuildInputs = [
          ghc'
          cabal-install
          python3
          binutils
          patchelf
        ]
        ++ nativeBuildInputs;
        inherit buildInputs;
      }
      ''
        set -euo pipefail
        export HOME="$TMPDIR/home" CABAL_DIR="$out/cabal" LANG=C.UTF-8
        mkdir -p "$HOME" "$CABAL_DIR" "$out/tree/${projectDir}" "$TMPDIR/repo"
        cp -r --no-preserve=mode ${filteredSrc}/. "$out/tree/${projectDir}/"
        ${lib.concatMapStrings (p: ''
          mkdir -p "$(dirname "$out/tree/${projectDir}/${p}")"
          cp -r --no-preserve=mode ${externalPaths.${p}} "$out/tree/${projectDir}/${p}"
        '') requiredExternalPaths}
        cd "$out/tree/${projectDir}"
        for file in ${repository}/repo/*; do
          if [ -e "$file" ]; then ln -s "$file" "$TMPDIR/repo/"; fi
        done
        cat > "$CABAL_DIR/config" <<EOF
        repository purified
          url: file+noindex://$TMPDIR/repo
        active-repositories: purified
        jobs: $NIX_BUILD_CORES
        EOF
        python3 ${./offline_project.py} --project-dir . --output-dir "$TMPDIR/project" \
          --remote ${repository}/remote.json --constraints ${constraints} \
          ${lib.optionalString (cabalFreeze != null) "--freeze ${cabalFreeze}"}
        cabalProject=(--project-dir="$PWD" --project-file="$TMPDIR/project/cabal.project")
        command cabal build "''${cabalProject[@]}" ${lib.escapeShellArgs cabalArgs} all --enable-shared
        python3 ${./check_plan.py} dist-newstyle/cache/plan.json ${units}
        command cabal build "''${cabalProject[@]}" ${lib.escapeShellArgs cabalArgs} all --enable-shared --offline
        cp dist-newstyle/cache/plan.json "$out/plan.json"
        python3 ${./check_native_products.py} "$out" ${spec} \
          ${lib.getBin stdenv.cc.libc}/bin/ldd
      '';
  projections = purifier.nativeProjections {
    inherit
      producer
      system
      runCommand
      python3
      ;
    libraries = lib.mapAttrs (key: _: "lib/${key}/lib${key}.so") nativeProducts;
    includeDirectories = [
      "include"
      "include/ghc"
    ];
    targetMetadata = lib.mapAttrs (
      _: p:
      p
      // {
        type = "shared-library";
        nativeModel = "${producer}/native-products.json";
        compiler = {
          name = "ghc";
          version = ghc'.version;
          path = toString ghc';
        };
      }
    ) nativeProducts;
  };
in
assert
  selected
  || throw "cabal-purifier: nativeProducts needs one locked package:flib:component, explicit distinct C exports including init/term, and process-once/single-foreign-thread GHC runtime";
assert lib.assertMsg (builtins.all (
  p: externalPaths ? ${p}
) requiredExternalPaths) "cabal-purifier: nativeProducts requires all locked externalPaths trees";
assert lib.assertMsg (
  stdenv.hostPlatform.isLinux && system == stdenv.hostPlatform.system
) "cabal-purifier: nativeProducts currently requires a native Linux build";
{
  inherit producer projections;
}
