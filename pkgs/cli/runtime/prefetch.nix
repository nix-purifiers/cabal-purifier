# SPDX-License-Identifier: MIT
#
# What `cabal-purifier prefetch` realizes for day-to-day development on one
# system, as one store path that a GC root keeps alive:
#
#   sources     the locked sources (repository.nix), which `cabal` builds
#               from offline
#   toolchain   only with explicit withToolchain: the packaged GHC and
#               cabal-install, plus HLS when available
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
  # A cabal.project.freeze kept outside the project, as an absolute path
  # string, or "" for the one in the project.
  cabalFreeze ? "",
  # Explicit convenience; default local adoption keeps the host runtime.
  withToolchain ? false,
}:
let
  pkgs = import nixpkgs { };
  lock =
    (import ../../../lib-overlays/default/read-lock.nix {
      src = /. + src;
      lockFile = /. + lockFile;
      cabalFreeze = if cabalFreeze == "" then null else /. + cabalFreeze;
    }).cabal;
  plan = lock.plan system;
  ghcAttr = lock.compilerAttr system;
  missing =
    attr:
    throw "cabal-purifier: nixpkgs has no ${attr} for the ${plan.compiler} the lock was made with.";
  ghc = pkgs.haskell.compiler.${ghcAttr} or (missing "haskell.compiler.${ghcAttr}");
  languageServer = pkgs.haskell.packages.${ghcAttr}.haskell-language-server or null;
  # realize.nix checks the lock, with checkLock of the purifier library.
  sources = import ./realize.nix {
    inherit
      lockFile
      src
      system
      nixpkgs
      purifier
      cabalFreeze
      ;
  };
  toolchain = pkgs.symlinkJoin {
    name = "cabal-purifier-toolchain";
    paths = [
      ghc
      pkgs.cabal-install
    ]
    ++ pkgs.lib.optional (languageServer != null) languageServer;
  };
in
pkgs.linkFarm "cabal-purifier-prefetch" (
  [
    {
      name = "sources";
      path = sources;
    }
  ]
  ++ pkgs.lib.optionals withToolchain [
    {
      name = "toolchain";
      path = toolchain;
    }
  ]
)
