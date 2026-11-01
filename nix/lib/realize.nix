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
}:
(import nixpkgs { }).callPackage ./repository.nix {
  lockFile = /. + lockFile;
  src = /. + src;
}
