# SPDX-License-Identifier: MIT
#
# The packages of the scope `pkgs.cabal-purifier`. The scope is the one
# attribute the default package overlay adds to a package set.
{ callPackage, lib, ... }:
{
  # The cabal-purifier command. It builds outside the flake, so it takes the
  # source of github:nix-purifiers/purifier from the library of this flake.
  cli = callPackage ./cli {
    version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
    purifierSource = lib.caisson.libManifest.sources.purifier;
  };

  # The builder (nix/lib/build-cabal-project.nix), a package for
  # callPackage. It takes the `purifier` namespace of
  # github:nix-purifiers/purifier from the library of this flake.
  buildCabalProject = callPackage ../nix/lib/build-cabal-project.nix {
    inherit (lib) purifier;
  };
}
