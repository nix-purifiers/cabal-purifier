# SPDX-License-Identifier: MIT
#
# What `cabal-purifier prefetch` realizes for day-to-day development on one
# system, as one store path that a GC root keeps alive:
#
#   sources     the locked sources (repository.nix), which `cabal` builds
#               from offline
#   toolchain   the GHC of the lock's plan, cabal-install, and the
#               haskell-language-server for that GHC, which an editor runs
{
  # The lockfile, as an absolute path string.
  lockFile,
  # The project root, as an absolute path string.
  src,
  # The system to prefetch for.
  system,
  # The nixpkgs the command was built with.
  nixpkgs,
  # The source of github:nix-purifiers/purifier the command was built with.
  purifier,
}:
let
  pkgs = import nixpkgs { };
  lock =
    (import ./read-lock.nix {
      src = /. + src;
      lockFile = /. + lockFile;
    }).cabal;
  plan = lock.plan system;
  ghcAttr = lock.compilerAttr system;
  missing =
    attr:
    throw "cabal-purifier: nixpkgs has no ${attr} for the ${plan.compiler} the lock was made with.";
  ghc = pkgs.haskell.compiler.${ghcAttr} or (missing "haskell.compiler.${ghcAttr}");
  languageServer =
    pkgs.haskell.packages.${ghcAttr}.haskell-language-server
      or (missing "haskell.packages.${ghcAttr}.haskell-language-server");
  # realize.nix checks the lock, with checkLock of the purifier library.
  sources = import ./realize.nix {
    inherit
      lockFile
      src
      system
      nixpkgs
      purifier
      ;
  };
  toolchain = pkgs.symlinkJoin {
    name = "cabal-purifier-toolchain";
    paths = [
      ghc
      pkgs.cabal-install
      languageServer
    ];
  };
in
pkgs.linkFarm "cabal-purifier-prefetch" [
  {
    name = "sources";
    path = sources;
  }
  {
    name = "toolchain";
    path = toolchain;
  }
]
