# SPDX-License-Identifier: MIT
#
# The `cabal-purifier` library namespace: `readLock`
# (nix/lib/read-lock.nix), the lock of a project in the shape every
# nix-purifier reads its lockfiles into, and `buildCabalProject`
# (nix/lib/build-cabal-project.nix), on the `purifier` namespace of
# github:nix-purifiers/purifier, which this flake lists in its projects.
{ ... }:
{

  overlay = final: prev: {
    cabal-purifier = (prev.cabal-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix;
      buildCabalProject = import ../../nix/lib/build-cabal-project.nix { inherit (final) purifier; };
    };
  };

}
