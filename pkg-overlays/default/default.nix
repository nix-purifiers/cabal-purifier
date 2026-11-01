# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cabal-purifier` (`.cli`), and the builder `pkgs.buildCabalProject`
# (nix/lib/build-cabal-project.nix) beside them, where nixpkgs keeps its
# own builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `cabal-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cabal-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildCabalProject = final.callPackage ../../nix/lib/build-cabal-project.nix { };
    };
}
