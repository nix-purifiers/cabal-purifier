# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cabal-purifier` (`.cli`), and the builder `pkgs.buildCabalProject`
# (nix/lib/build-cabal-project.nix) beside them, where nixpkgs keeps its
# own builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `cabal-purifier/default`, which its package sets apply by default.
#
# Both take github:nix-purifiers/purifier from this flake's library: the
# builder takes its `purifier` namespace, and the command takes its source,
# since the command builds outside the flake.
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
      buildCabalProject = final.callPackage ../../nix/lib/build-cabal-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
