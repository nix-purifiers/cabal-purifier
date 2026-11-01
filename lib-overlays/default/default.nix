# SPDX-License-Identifier: MIT
#
# The `cabal-purifier` library namespace: `readLock`
# (nix/lib/read-lock.nix), the lock of a project in the shape every
# nix-purifier reads its lockfiles into. The builder needs a package set,
# so it is the package `buildCabalProject` that the default package
# overlay adds.
{ ... }:
{

  overlay = final: prev: {
    cabal-purifier = (prev.cabal-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix;
    };
  };

}
