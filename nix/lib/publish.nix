# SPDX-License-Identifier: MIT
#
# What `cabal-purifier publish` builds: the source tarball (`sdist`) or the
# documentation tarball (`docs`) of one package of the project, by the
# same builder as any other build of the project. The local packages
# outside the project come from their places beside the checkout.
{
  # The project root, as an absolute path string.
  src,
  # The package of the project.
  package,
  # `sdist` or `docs`.
  artifact,
  # The nixpkgs the command was built with.
  nixpkgs,
  # The source of github:nix-purifiers/purifier the command was built with.
  purifier,
}:
let
  pkgs = import nixpkgs { };
  buildCabalProject = pkgs.callPackage ./build-cabal-project.nix {
    purifier = import ./purifier.nix { inherit pkgs purifier; };
  };
  root = /. + src;
  lock = import ./lock.nix { lockFile = root + "/cabal-purifier.lock.json"; };
  project = buildCabalProject {
    src = root;
    # Nix resolves the `..` of each path when it makes the path.
    externalPaths = pkgs.lib.genAttrs lock.externalPaths (p: /. + "${src}/${p}");
  };
in
(project.packages.${package}
  or (throw "cabal-purifier: the project has no package ${package}; it has ${builtins.concatStringsSep ", " (builtins.attrNames project.packages)}.")
).${artifact}
