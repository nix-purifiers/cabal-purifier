# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;

  # The `packages` output has the derivations of the scope
  # `pkgs.cabal-purifier`. The scope also holds the builder, which is a
  # function.
  purifier.scope = "cabal-purifier";

  caisson.libOverlays.exported = libOverlays: {
    inherit (libOverlays) default;
  };

  # `nix run github:nix-purifiers/cabal-purifier -- lock` locks the project
  # in the current directory.
  perSystem =
    { pkgs, ... }:
    {
      packages.default = pkgs.cabal-purifier.cli;
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              purified = pkgs.extend self.overlays.default;
              inherit (self.packages.${system}) cli;
              inherit (inputs) shellcheck;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
