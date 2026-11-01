# SPDX-License-Identifier: MIT
#
# The `purifier` library namespace of github:nix-purifiers/purifier, for
# the cabal-purifier command, which builds with `nix-build` on a plain
# nixpkgs rather than through the flake. The library's root default.nix
# is its entry point for evaluations outside a flake. The flake's package
# overlay takes the namespace from the composed library instead.
{
  pkgs,
  # The source of github:nix-purifiers/purifier, as a path string.
  purifier,
}:
import (/. + purifier) { inherit (pkgs) lib; }
