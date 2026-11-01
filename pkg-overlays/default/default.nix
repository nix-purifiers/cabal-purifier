# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cabal-purifier` (`.cli`). A consumer that lists this flake in
# `projects` holds it as `cabal-purifier/default`, which its package sets
# apply by default. The builder is in the library, as
# `lib.cabal-purifier.buildCabalProject`.
#
# The command builds outside the flake, so it takes the source of
# github:nix-purifiers/purifier from this flake's library.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cabal-purifier";
  purifierSource = closure-lib.caisson.libManifest.sources.purifier;
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      cabal-purifier = added.cabal-purifier // {
        cli = added.cabal-purifier.cli.override { inherit purifierSource; };
      };
    };
}
