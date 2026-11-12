# SPDX-License-Identifier: MIT
#
# The packages of the scope `pkgs.cabal-purifier`. The scope is the one
# attribute the default package overlay adds to a package set.
{ callPackage, lib, ... }:
{
  # The cabal-purifier command. It builds outside the flake, so it takes the
  # source of github:nix-purifiers/purifier from the library of this flake.
  cli = callPackage ./cli {
    version = import ./version.nix;
    purifierSource = lib.caisson.libManifest.sources.purifier;
  };

  # Explicit bundled-runtime convenience; the default CLI uses the host GHC.
  cliWithToolchain = callPackage ./cli {
    version = import ./version.nix;
    purifierSource = lib.caisson.libManifest.sources.purifier;
    withToolchain = true;
  };

  # The builder (pkgs/build-cabal-project/default.nix), a package for
  # callPackage. It takes the `purifier` namespace of
  # github:nix-purifiers/purifier from the library of this flake.
  buildCabalProject = callPackage ./build-cabal-project/default.nix {
    inherit (lib) purifier;
  };
}
