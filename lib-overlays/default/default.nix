# SPDX-License-Identifier: MIT
#
# The `cabal-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildCabalProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    cabal-purifier = prev.cabal-purifier or { };
  };

}
