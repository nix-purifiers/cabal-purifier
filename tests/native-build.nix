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
  build = pkgs.callPackage ../nix/lib/build-cabal-project.nix {
    purifier = import ../nix/lib/purifier.nix { inherit pkgs purifier; };
  };
in
import ./native-products.nix {
  inherit pkgs build;
  src = /. + src;
  externalSrc = /. + externalSrc;
  competitorSrc = /. + competitorSrc;
  competitorExternalSrc = /. + competitorExternalSrc;
}
