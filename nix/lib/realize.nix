# SPDX-License-Identifier: MIT
#
# What the lock run's check and the `cabal` shim build: the locked
# sources of a lockfile for one system (repository.nix), the same
# derivation the sandboxed build uses. The command builds it with an
# out-link, which is the GC root that keeps every locked file alive.
{
  # The lockfile, as an absolute path string.
  lockFile,
  # The project root, as an absolute path string.
  src,
  # The system whose downloads to realize.
  system,
  # The nixpkgs the command was built with.
  nixpkgs,
  # The source of github:nix-purifiers/purifier the command was built with.
  purifier,
}:
let
  pkgs = import nixpkgs { };
  purifierLib = import ./purifier.nix { inherit pkgs purifier; };
  locked = purifierLib.checkLock (
    import ./read-lock.nix {
      src = /. + src;
      lockFile = /. + lockFile;
    }
  );
in
pkgs.callPackage ./repository.nix {
  purifier = purifierLib;
  lock = locked.cabal;
  entries = purifierLib.entriesFor system locked;
  src = /. + src;
}
