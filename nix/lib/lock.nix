# SPDX-License-Identifier: MIT
#
# Reads a cabal-purifier lockfile (written by `cabal-purifier lock`). The
# lockfile holds:
#
#   downloads        the locked downloads, in the shapes of the shared
#                    nix-purifiers library (see fetch.nix)
#   repository       the files of the local no-index repository that the
#                    builds resolve Cabal's packages from: each is a
#                    download (`from`), a tarball packed from a locked
#                    checkout (`pack`), or a file of the project (`project`)
#   remotePackages   the package URLs in the project's `packages` field,
#                    each with the download that holds its tarball
#   externalPaths    the local packages outside the project, by their path
#                    relative to the project root
#   systems.<system> the plan for that system: the compiler and every unit
#                    with its version and flags
#   outputs          the project's own packages and their components
#   definition       the project files the lock was made from, with the
#                    SRI hash of each
#   configuration    whether the plan enables tests and benchmarks
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_".
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;

  downloadsByPath = builtins.listToAttrs (
    map (d: {
      name = d.path;
      value = d;
    }) lock.downloads
  );

  # What is inconsistent in the lockfile: references to downloads it does
  # not hold, and packages of a plan that no locked source provides. The
  # cabal-purifier command makes the same checks.
  repositoryFiles = builtins.listToAttrs (
    map (f: {
      name = f.file;
      value = true;
    }) lock.repository
  );
  remotePackages = builtins.listToAttrs (
    map (r: {
      name = r.package;
      value = true;
    }) lock.remotePackages
  );
  sourceOf = f: f.from or f.pack.from or null;
  problems =
    map (f: "the repository file ${f.file} names no download ${sourceOf f}") (
      builtins.filter (f: sourceOf f != null && !(downloadsByPath ? ${sourceOf f})) lock.repository
    )
    ++ map (r: "the package URL ${r.uri} names no download ${r.from}") (
      builtins.filter (r: !(downloadsByPath ? ${r.from})) lock.remotePackages
    )
    ++ builtins.concatLists (
      builtins.attrValues (
        builtins.mapAttrs (
          system: plan:
          map (u: "the plan for ${system} uses ${u.name}-${u.version}, which no locked source provides") (
            builtins.filter (
              u:
              !u.installed
              && !u.local
              && !(repositoryFiles ? "${u.name}-${u.version}.tar.gz")
              && !(remotePackages ? "${u.name}-${u.version}")
            ) plan.units
          )
        ) lock.systems
      )
    );
in
assert
  lock.version == supportedVersion
  || throw "cabal-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `cabal-purifier relock` with the cabal-purifier version that provides this library.";
assert
  problems == [ ]
  || throw "cabal-purifier: ${toString lockFile} is damaged: ${builtins.concatStringsSep "; " problems}. Run `cabal-purifier relock` to write it again.";
lock
// {
  inherit storeName downloadsByPath;

  # The fetch name of a download: its file name, made a valid store name.
  downloadName = download: storeName (baseNameOf download.path);

  # The download a repository file or remote package names.
  download =
    path: downloadsByPath.${path} or (throw "cabal-purifier: the lockfile names no download ${path}");
}
