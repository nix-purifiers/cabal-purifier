# SPDX-License-Identifier: MIT
#
# What `cabal-purifier cabal` and the lock run's check build: the locked
# sources of a lockfile (repository.nix), the same derivation the
# sandboxed build uses. The command builds it with an out-link, which is
# the GC root that keeps every locked file alive.
{
  # The lockfile, as an absolute path string.
  lockFile,
  # The project root, as an absolute path string.
  src,
  # The nixpkgs the command was built with.
  nixpkgs,
  # The source of github:nix-purifiers/purifier the command was built with.
  purifier,
}:
let
  pkgs = import nixpkgs { };
in
pkgs.callPackage ./repository.nix {
  purifier = import ./purifier.nix { inherit pkgs purifier; };
  lockFile = /. + lockFile;
  src = /. + src;
}
