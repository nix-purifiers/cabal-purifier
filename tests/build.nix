# SPDX-License-Identifier: MIT
#
# Builds a project outside the flake's checks, for tests/vcs.sh: the
# `project` build of the Cabal project at `src` (an absolute path string),
# with the nixpkgs at `nixpkgs` and the source of
# github:nix-purifiers/purifier at `purifier` (a path string).
{
  src,
  purifier,
  nixpkgs ? <nixpkgs>,
}:
let
  pkgs = import nixpkgs { };
  buildCabalProject = pkgs.callPackage ../nix/lib/build-cabal-project.nix {
    purifier = import ../nix/lib/purifier.nix { inherit pkgs purifier; };
  };
in
(buildCabalProject { src = /. + src; }).project
