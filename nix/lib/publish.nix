# SPDX-License-Identifier: MIT
#
# What `cabal-purifier publish` builds: the source tarball (`sdist`) or the
# documentation tarball (`docs`) of one package of the project, by the
# same builder as any other build of the project.
{
  # The project root, as an absolute path string.
  src,
  # The package of the project.
  package,
  # `sdist` or `docs`.
  artifact,
  # The nixpkgs the command was built with.
  nixpkgs,
}:
let
  pkgs = import nixpkgs { };
  buildCabalProject = pkgs.callPackage ./build-cabal-project.nix { };
  project = buildCabalProject { src = /. + src; };
in
(project.packages.${package}
  or (throw "cabal-purifier: the project has no package ${package}; it has ${builtins.concatStringsSep ", " (builtins.attrNames project.packages)}.")
).${artifact}
