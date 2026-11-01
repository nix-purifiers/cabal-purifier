# SPDX-License-Identifier: MIT
#
# Builds a project outside the flake's checks, for tests/vcs.sh: the
# `project` build of the Cabal project at `src` (an absolute path string),
# with the nixpkgs at `nixpkgs`.
{
  src,
  nixpkgs ? <nixpkgs>,
}:
let
  pkgs = import nixpkgs { };
  buildCabalProject = pkgs.callPackage ../nix/lib/build-cabal-project.nix { };
in
(buildCabalProject { src = /. + src; }).project
