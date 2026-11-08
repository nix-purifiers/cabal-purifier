# SPDX-License-Identifier: MIT
{
  src,
  externalSrc,
  nixpkgs,
  purifier,
  missingSymbol ? false,
}:
let
  pkgs = import nixpkgs { };
  build = pkgs.callPackage ../nix/lib/build-cabal-project.nix {
    purifier = import ../nix/lib/purifier.nix { inherit pkgs purifier; };
  };
  p = import ./native/product.nix;
in
(build {
  src = /. + src;
  externalPaths."../foreign-external" = /. + externalSrc;
  nativeProducts.answer =
    p
    // pkgs.lib.optionalAttrs missingSymbol {
      exports = p.exports ++ [ "purifier_missing_export" ];
    };
}).projections.native
