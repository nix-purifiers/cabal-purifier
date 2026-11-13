# SPDX-License-Identifier: MIT
{
  src,
  externalSrc,
  competitorSrc,
  competitorExternalSrc,
  nixpkgs,
  purifier,
}:
let
  pkgs = import nixpkgs { };
  build = pkgs.callPackage ../pkgs/build-cabal-project/default.nix {
    purifier = import ../pkgs/cli/runtime/purifier.nix { inherit pkgs purifier; };
  };
in
import ./native-products.nix {
  inherit pkgs build;
  src = /. + src;
  externalSrc = /. + externalSrc;
  competitorSrc = /. + competitorSrc;
  competitorExternalSrc = /. + competitorExternalSrc;
}
