# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to a package set, the
# scope `pkgs.cabal-purifier` (made with lib.makeScope), which holds the
# builder `buildCabalProject` and the command `cli` (pkgs/default.nix).
# `pkgs.cabal-purifier.overrideScope` replaces what the scope shares, and
# `pkgs.cabal-purifier.buildCabalProject.override` replaces what the
# builder takes. A consumer that lists this flake in `projects` holds it as
# `cabal-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cabal-purifier";
}
