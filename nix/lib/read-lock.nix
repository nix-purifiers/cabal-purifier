# SPDX-License-Identifier: MIT
#
# readLock: the lock of a Cabal project in memory, in the shape that every
# nix-purifier reads its lockfiles into (CONTRACT.md of
# github:nix-purifiers/purifier):
#
#   purifier  "cabal-purifier"
#   entries   the downloads of the lock, as entries of the purifier library.
#             A download that only some systems' plans use carries
#             `systems`, the list of those systems.
#   outputs   the packages of the project and their components
#   problems  why the lockfile cannot be used: a stale, tampered, malformed
#             or incomplete lockfile, each naming `cabal-purifier lock`
#   cabal     the lockfile itself, for the builder
#
# Cabal records no hashes of the downloads it plans, so everything a build
# needs is in cabal-purifier.lock.json (written by `cabal-purifier lock`):
#
#   version          the lock format version (lock-version.nix)
#   hash             the SRI SHA-256 of the lockfile's JSON without `hash`,
#                    as builtins.toJSON writes it: keys sorted, no spaces
#   downloads        the downloads, as entries of the purifier library. A
#                    download at repository/<file> is that file of the
#                    no-index repository the builds resolve packages from.
#   repository       the other files of that repository: each is a tarball
#                    packed from a locked checkout (`pack`) or a file of the
#                    project (`project`)
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
#   indexState       the Hackage index state the lock planned with, which
#                    the next `cabal-purifier lock` plans with again
{
  # The project root, where cabal.project (or the package's .cabal file)
  # is.
  src,
  # The lockfile. A lockfile kept outside `src` takes the place of any
  # lockfile in it.
  lockFile ? src + "/cabal-purifier.lock.json",
}:
let
  inherit (builtins)
    attrNames
    concatLists
    concatMap
    concatStringsSep
    filter
    isAttrs
    listToAttrs
    map
    match
    ;

  supportedVersion = import ./lock-version.nix;

  raw = builtins.fromJSON (builtins.readFile lockFile);

  damaged =
    problem:
    "cabal-purifier: ${toString lockFile} is damaged: ${problem}. Run `cabal-purifier lock` to write it again.";

  sections = [
    "version"
    "hash"
    "configuration"
    "definition"
    "downloads"
    "repository"
    "remotePackages"
    "externalPaths"
    "systems"
    "outputs"
  ];

  # The first problem of the lockfile's form, which leaves the rest of it
  # unread.
  formProblem =
    if !isAttrs raw then
      damaged "it is not a JSON object"
    else if (raw.version or null) != supportedVersion then
      "cabal-purifier: ${toString lockFile} has lock format version ${
        toString (raw.version or "none")
      }; this library reads version ${toString supportedVersion}. Run `cabal-purifier lock` with the cabal-purifier version that provides this library."
    else if filter (s: !(raw ? ${s})) sections != [ ] then
      damaged "it has no ${concatStringsSep ", " (filter (s: !(raw ? ${s})) sections)}"
    else if raw.hash != contentHash then
      damaged "its content does not match its hash, so it was changed after `cabal-purifier lock` wrote it"
    else
      null;

  contentHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs raw [ "hash" ]));
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  downloadsByPath = listToAttrs (
    map (d: {
      name = d.path;
      value = d;
    }) raw.downloads
  );

  # The package each download provides: <name>-<version>.
  packOf = listToAttrs (
    concatMap (
      f:
      if f ? pack then
        [
          {
            name = f.pack.from;
            value = f.pack.root;
          }
        ]
      else
        [ ]
    ) raw.repository
  );
  remoteOf = listToAttrs (
    map (r: {
      name = r.from;
      value = r.package;
    }) raw.remotePackages
  );
  packageOf =
    d:
    let
      file = match "repository/(.*)\\.(tar\\.gz|cabal)" d.path;
    in
    if file != null then builtins.head file else packOf.${d.path} or remoteOf.${d.path} or null;

  # The packages each system's plan takes from a locked source.
  planned = builtins.mapAttrs (
    _: plan:
    listToAttrs (
      map (u: {
        name = "${u.name}-${u.version}";
        value = true;
      }) (filter (u: !u.installed && !u.local) plan.units)
    )
  ) raw.systems;
  allSystems = attrNames raw.systems;
  systemsOf =
    d:
    let
      package = packageOf d;
      using = filter (s: package != null && planned.${s} ? ${package}) allSystems;
    in
    if package == null || using == allSystems then null else using;

  entries = map (
    d:
    let
      systems = systemsOf d;
    in
    if systems == null then d else d // { inherit systems; }
  ) raw.downloads;

  # References to downloads the lockfile does not hold, and packages of a
  # plan that no locked source provides. The cabal-purifier command makes
  # the same checks.
  repositoryFiles = listToAttrs (
    map
      (file: {
        name = file;
        value = true;
      })
      (
        concatMap (
          d:
          let
            m = match "repository/(.*)" d.path;
          in
          if m == null then [ ] else m
        ) raw.downloads
        ++ map (f: f.file) raw.repository
      )
  );
  remotePackages = listToAttrs (
    map (r: {
      name = r.package;
      value = true;
    }) raw.remotePackages
  );
  incomplete =
    map (f: "the repository file ${f.file} names no download ${f.pack.from}") (
      filter (f: f ? pack && !(downloadsByPath ? ${f.pack.from})) raw.repository
    )
    ++ map (r: "the package URL ${r.uri} names no download ${r.from}") (
      filter (r: !(downloadsByPath ? ${r.from})) raw.remotePackages
    )
    ++ concatLists (
      map (
        system:
        map (u: "the plan for ${system} uses ${u.name}-${u.version}, which no locked source provides") (
          filter (
            u:
            !u.installed
            && !u.local
            && !(repositoryFiles ? "${u.name}-${u.version}.tar.gz")
            && !(remotePackages ? "${u.name}-${u.version}")
          ) raw.systems.${system}.units
        )
      ) allSystems
    );

  # The project files that changed since the lock.
  sri =
    file:
    builtins.convertHash {
      hash = builtins.hashFile "sha256" file;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
  staleFiles = filter (
    f: !(builtins.pathExists (src + "/${f}")) || sri (src + "/${f}") != raw.definition.${f}
  ) (attrNames raw.definition);

  problems =
    if formProblem != null then
      [ formProblem ]
    else
      (if incomplete == [ ] then [ ] else [ (damaged (concatStringsSep "; " incomplete)) ])
      ++ (
        if staleFiles == [ ] then
          [ ]
        else
          [
            "cabal-purifier: the lockfile ${toString lockFile} is out of date: ${concatStringsSep ", " staleFiles} changed since `cabal-purifier lock` wrote it. Run `cabal-purifier lock`."
          ]
      );

  usable = formProblem == null;
in
{
  purifier = "cabal-purifier";
  entries = if usable then entries else [ ];
  outputs = if usable then raw.outputs.packages else { };
  inherit problems;
  cabal = raw // {
    # The download a repository file or remote package names.
    download =
      path: downloadsByPath.${path} or (throw "cabal-purifier: the lockfile names no download ${path}");

    # The plan for a system.
    plan =
      system:
      raw.systems.${system}
        or (throw "cabal-purifier: the lockfile has no plan for ${system}; it holds ${concatStringsSep ", " allSystems}. Run `cabal-purifier lock`.");

    # The attribute of nixpkgs' haskell.compiler and haskell.packages for
    # the GHC of a system's plan, such as ghc9103 for ghc-9.10.3.
    compilerAttr =
      system:
      "ghc"
      + builtins.replaceStrings [ "." ] [ "" ] (
        builtins.substring 4 100 (raw.systems.${system}.compiler or "ghc-unknown")
      );
  };
}
