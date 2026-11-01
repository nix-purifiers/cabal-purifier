# SPDX-License-Identifier: MIT
#
# What `cabal-purifier publish` builds: the project's `release`, the source
# tarballs, or with `documentation` the documentation tarball of one
# package, by the same builder as any other build of the project. The
# local packages outside the project come from their places beside the
# checkout.
{
  # The project root, as an absolute path string.
  src,
  # The lockfile, as an absolute path string.
  lockFile,
  # The package whose documentation to build, or "" for the release.
  documentation,
  # The nixpkgs the command was built with.
  nixpkgs,
  # The source of github:nix-purifiers/purifier the command was built with.
  purifier,
  # A cabal.project.freeze kept outside the project, as an absolute path
  # string, or "" for the one in the project.
  cabalFreeze ? "",
}:
let
  pkgs = import nixpkgs { };
  buildCabalProject = pkgs.callPackage ./build-cabal-project.nix {
    purifier = import ./purifier.nix { inherit pkgs purifier; };
  };
  root = /. + src;
  freeze = if cabalFreeze == "" then null else /. + cabalFreeze;
  lock =
    (import ./read-lock.nix {
      src = root;
      lockFile = /. + lockFile;
      cabalFreeze = freeze;
    }).cabal;
  project = buildCabalProject {
    src = root;
    lockFile = /. + lockFile;
    cabalFreeze = freeze;
    # Nix resolves the `..` of each path when it makes the path.
    externalPaths = pkgs.lib.genAttrs lock.externalPaths (p: /. + "${src}/${p}");
  };
in
if documentation == "" then
  project.release
else
  (project.packages.${documentation}
    or (throw "cabal-purifier: the project has no package ${documentation}; it has ${builtins.concatStringsSep ", " (builtins.attrNames project.packages)}.")
  ).docs
