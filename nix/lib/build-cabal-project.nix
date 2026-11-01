# SPDX-License-Identifier: MIT
#
# buildCabalProject: the sandboxed builds of a Cabal project, from the
# lockfile `cabal-purifier lock` writes at the project root.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# cabal-purifier overlay (`overlays.default`) adds it to the package set as
# `buildCabalProject`, so a package written for callPackage takes it like
# any other dependency:
#
#   { buildCabalProject }: (buildCabalProject { src = ./.; }).packages.my-app.executables.my-app
#
# and `buildCabalProject.override` replaces what it takes from the set.
# The builder returns
#
#   project          every component of every package of the project, built
#                    by `cabal build all` against the locked plan, with
#                    their binaries under packages/<package>/ and plan.json
#   repository       the locked sources: the no-index repository the builds
#                    resolve packages from, and the unpacked package URLs
#   packages.<name>  for each package of the project:
#     sdist                the source tarball `cabal sdist` makes, the file
#                          `cabal upload` publishes; `tarball` names it
#     docs                 the documentation tarball for Hackage, from
#                          `cabal haddock --haddock-for-hackage`; `tarball`
#                          names it
#     executables.<name>   each executable, at bin/<name>
#     testSuites.<name>    a run of each test suite, in a copy of the
#                          package's directory
#     benchmarks.<name>    each benchmark, at bin/<name>
#     library, sublibraries, foreignLibraries
#                          the package's library components, by name, as
#                          the lock records them
#
# The lock records the outputs, so all of these are known when Nix
# evaluates, without building anything.
{
  lib,
  stdenv,
  stdenvNoCC,
  callPackage,
  runCommand,
  writeText,
  haskell,
  cabal-install,
  python3,
  # The `purifier` library namespace of github:nix-purifiers/purifier. The
  # cabal-purifier package overlay passes it.
  purifier,
}:
{
  # The root of the Cabal project, where cabal.project (or the package's
  # .cabal file) is.
  src,
  # The lockfile; the default is the one `cabal-purifier lock` writes at the
  # project root.
  lockFile ? src + "/cabal-purifier.lock.json",
  # The name of `project`.
  name ? "cabal-project",
  # The GHC that builds the project. The default is nixpkgs' GHC of the
  # exact version the lock was made with.
  ghc ? null,
  # Tools and libraries outside Cabal: pkg-config and zlib for a package
  # with `pkgconfig-depends: zlib`, for example.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Runs `cabal test all` in the `project` build.
  doCheck ? false,
  # More arguments for every cabal command of the builds, such as
  # `--ghc-options=-Werror`.
  cabalFlags ? [ ],
  # Replaces nixpkgs' fetchurl for files. It is called with
  # { name, urls, hash }, and is the place for credentials (nixpkgs'
  # fetchurl takes `netrcPhase`).
  fetchurl ? null,
  # Replaces nixpkgs' fetchgit for source repositories, as for a private
  # repository that needs credentials. It is called with the arguments of
  # fetchgit.
  fetchgit ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out version control and
  # Cabal's build directory.
  srcFilter ? null,
  # The trees of the local packages outside the project, by the path the
  # lock gives them (relative to the project root), such as
  # { "../shared" = inputs.shared; }. The lock lists them as externalPaths.
  externalPaths ? { },
  # The system whose plan the builds use.
  system ? stdenv.hostPlatform.system,
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  # The lock is stale when a project file it was made from has changed.
  sri =
    file:
    builtins.convertHash {
      hash = builtins.hashFile "sha256" file;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
  staleFiles = lib.filter (
    f: !(builtins.pathExists (src + "/${f}")) || sri (src + "/${f}") != lock.definition.${f}
  ) (lib.attrNames lock.definition);

  plan =
    lock.systems.${system}
      or (throw "cabal-purifier: the lockfile has no plan for ${system}; it holds ${lib.concatStringsSep ", " (lib.attrNames lock.systems)}. Run `cabal-purifier relock`.");

  ghcVersion = lib.removePrefix "ghc-" plan.compiler;
  ghcAttr = "ghc" + lib.replaceStrings [ "." ] [ "" ] ghcVersion;
  ghc' =
    if ghc != null then
      ghc
    else
      haskell.compiler.${ghcAttr}
        or (throw "cabal-purifier: nixpkgs has no haskell.compiler.${ghcAttr} for the ${plan.compiler} the lock was made with; pass `ghc`.");

  repository = callPackage ./repository.nix {
    inherit
      purifier
      lockFile
      src
      fetchurl
      fetchgit
      ;
  };

  # The constraints that make Cabal resolve to the locked plan: each
  # package at its locked version and flags, and each package the compiler
  # provides taken from the compiler.
  flagText =
    flags: lib.concatStringsSep " " (lib.mapAttrsToList (f: on: (if on then "+" else "-") + f) flags);
  constraintsOf =
    u:
    if u.installed then
      [ "any.${u.name} installed" ]
    else
      [ "any.${u.name} ==${u.version}" ]
      ++ lib.optional (u.flags != { }) "any.${u.name} ${flagText u.flags}";
  constraints = writeText "cabal-purifier-constraints" (
    lib.concatMapStrings (c: c + "\n") (lib.concatMap constraintsOf plan.units)
  );
  units = writeText "cabal-purifier-units.json" (builtins.toJSON plan.units);

  # The build lays the project and its external local packages out at the
  # same relative positions as in the checkout: the project goes below as
  # many placeholder directories as the deepest `../` climbs, so that each
  # external path resolves inside the build's tree.
  hasExternal = lock.externalPaths != [ ];
  missingExternal = lib.filter (p: !(externalPaths ? ${p})) lock.externalPaths;
  climbs =
    p:
    let
      count =
        segments: if segments != [ ] && lib.head segments == ".." then 1 + count (lib.tail segments) else 0;
    in
    count (lib.splitString "/" p);
  depth = lib.foldl' lib.max 0 (map climbs lock.externalPaths);
  projectDir =
    if hasExternal then
      lib.concatMapStrings (i: "_parent${toString i}/") (lib.range 1 depth) + "project"
    else
      ".";
  placeExternalPaths = lib.optionalString hasExternal ''
    tree="$TMPDIR/tree"
    mkdir -p "$tree/${projectDir}"
    cp -r . "$tree/${projectDir}"
    ${lib.concatMapStrings (p: ''
      mkdir -p "$(dirname "$tree/${projectDir}/${p}")"
      cp -r --no-preserve=mode ${externalPaths.${p}} "$tree/${projectDir}/${p}"
    '') lock.externalPaths}
    cd "$tree/${projectDir}"
  '';

  # Version control, Cabal's build directory and the results of nix build
  # never take part in a build.
  defaultSrcFilter =
    path: type:
    let
      base = baseNameOf path;
    in
    !(base == ".git" || base == "dist-newstyle" || lib.hasPrefix "result" base);

  filteredSrc = builtins.path {
    path = src;
    name = "cabal-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  cabalArgs = [
    (if lock.configuration.tests then "--enable-tests" else "--disable-tests")
    (if lock.configuration.benchmarks then "--enable-benchmarks" else "--disable-benchmarks")
    "--with-compiler=${ghc'}/bin/ghc"
  ]
  ++ cabalFlags;

  # The environment shared by every build: a Cabal directory whose only
  # repository is the locked one, and the offline copy of the project's
  # configuration. `cabal` is a shell function from here on, with the
  # arguments every command takes.
  setupCabal = ''
    export HOME="$TMPDIR/home"
    export CABAL_DIR="$TMPDIR/cabal"
    export LANG=C.UTF-8
    mkdir -p "$HOME" "$CABAL_DIR" "$TMPDIR/repo"
    for file in ${repository}/repo/*; do
      if [ -e "$file" ]; then
        ln -s "$file" "$TMPDIR/repo/"
      fi
    done
    cat > "$CABAL_DIR/config" <<EOF
    repository purified
      url: file+noindex://$TMPDIR/repo
    active-repositories: purified
    jobs: $NIX_BUILD_CORES
    EOF
    python3 ${./offline_project.py} \
      --project-dir . \
      --output-dir "$TMPDIR/project" \
      --remote ${repository}/remote.json \
      --constraints ${constraints}
    # The project directory is absolute: Cabal configures each package
    # from another working directory, where a relative one would not
    # resolve.
    cabalProject=(--project-dir="$PWD" --project-file="$TMPDIR/project/cabal.project")
    cabal() {
      command cabal "$1" "''${cabalProject[@]}" ${lib.escapeShellArgs cabalArgs} "''${@:2}"
    }
  '';

  outputs = lock.outputs.packages;

  # Installs each executable, test suite and benchmark of a package under
  # packages/<package>/ in the output.
  installComponents = lib.concatStrings (
    lib.mapAttrsToList (
      pkg: p:
      lib.concatMapStrings (exe: ''
        install -D "$(cabal list-bin ${lib.escapeShellArg "${pkg}:exe:${exe}"})" "$out/packages/${pkg}/bin/${exe}"
        mkdir -p "$out/bin"
        ln -sf "$out/packages/${pkg}/bin/${exe}" "$out/bin/${exe}"
      '') p.executables
      + lib.optionalString lock.configuration.tests (
        lib.concatMapStrings (t: ''
          install -D "$(cabal list-bin ${lib.escapeShellArg "${pkg}:test:${t}"})" "$out/packages/${pkg}/tests/${t}"
        '') p.testSuites
      )
      + lib.optionalString lock.configuration.benchmarks (
        lib.concatMapStrings (b: ''
          install -D "$(cabal list-bin ${lib.escapeShellArg "${pkg}:bench:${b}"})" "$out/packages/${pkg}/benchmarks/${b}"
        '') p.benchmarks
      )
    ) outputs
  );

  mkBuild =
    {
      suffix,
      withDocs,
    }:
    assert
      staleFiles == [ ]
      || throw "cabal-purifier: the lockfile is out of date: ${lib.concatStringsSep ", " staleFiles} changed since `cabal-purifier lock`. Run `cabal-purifier lock`.";
    assert
      missingExternal == [ ]
      || throw "cabal-purifier: the project has local packages outside it (${lib.concatStringsSep ", " missingExternal}); pass their trees as `externalPaths`.";
    stdenv.mkDerivation {
      name = name + suffix;
      src = filteredSrc;
      nativeBuildInputs = [
        ghc'
        cabal-install
        python3
      ]
      ++ nativeBuildInputs;
      inherit buildInputs;
      doCheck = doCheck && !withDocs;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${placeExternalPaths}
        ${setupCabal}
        cabal build all
        python3 ${./check_plan.py} dist-newstyle/cache/plan.json ${units}
        ${lib.optionalString withDocs ''
          cabal haddock all --haddock-for-hackage
        ''}
        runHook postBuild
      '';
      checkPhase = ''
        runHook preCheck
        cabal test all
        runHook postCheck
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp dist-newstyle/cache/plan.json "$out/plan.json"
        ${
          if withDocs then
            ''
              mkdir -p "$out/docs"
              cp dist-newstyle/*-docs.tar.gz "$out/docs/"
            ''
          else
            installComponents
        }
        runHook postInstall
      '';
      passthru = {
        ghc = ghc';
        inherit lock repository projectDir;
      };
    };

  project = mkBuild {
    suffix = "";
    withDocs = false;
  };
  documentation = mkBuild {
    suffix = "-docs";
    withDocs = true;
  };

  mkSdist =
    pkg: p:
    let
      fileName = "${pkg}-${p.version}.tar.gz";
      sdist = stdenvNoCC.mkDerivation {
        pname = "${pkg}-sdist";
        inherit (p) version;
        src = filteredSrc;
        nativeBuildInputs = [
          ghc'
          cabal-install
          python3
        ];
        dontConfigure = true;
        dontFixup = true;
        buildPhase = ''
          runHook preBuild
          ${placeExternalPaths}
          ${setupCabal}
          # sdist takes the project, not the build configuration.
          command cabal sdist "''${cabalProject[@]}" ${lib.escapeShellArg pkg} --output-directory="$out"
          runHook postBuild
        '';
        dontInstall = true;
        passthru.tarball = "${sdist}/${fileName}";
      };
    in
    sdist;

  mkDocs =
    pkg: p:
    let
      fileName = "${pkg}-${p.version}-docs.tar.gz";
      docs = runCommand "${pkg}-${p.version}-docs" { passthru.tarball = "${docs}/${fileName}"; } ''
        mkdir -p "$out"
        ln -s ${documentation}/docs/${fileName} "$out/${fileName}"
      '';
    in
    docs;

  mkExecutable =
    pkg: exe:
    runCommand exe { meta.mainProgram = exe; } ''
      mkdir -p "$out/bin"
      ln -s ${project}/packages/${pkg}/bin/${exe} "$out/bin/${exe}"
    '';

  mkBenchmark =
    pkg: bench:
    runCommand bench { meta.mainProgram = bench; } ''
      mkdir -p "$out/bin"
      ln -s ${project}/packages/${pkg}/benchmarks/${bench} "$out/bin/${bench}"
    '';

  # A test suite runs in a writable copy of its package's directory, where
  # Cabal runs it too.
  mkTestSuite =
    pkg: p: test:
    runCommand "${pkg}-test-${test}" { } ''
      cp -r --no-preserve=mode ${filteredSrc}/${p.dir} "$TMPDIR/package"
      cd "$TMPDIR/package"
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      ${project}/packages/${pkg}/tests/${test}
      touch "$out"
    '';

  packages = lib.mapAttrs (pkg: p: {
    inherit (p)
      version
      library
      sublibraries
      foreignLibraries
      ;
    sdist = mkSdist pkg p;
    docs = mkDocs pkg p;
    executables = lib.genAttrs p.executables (mkExecutable pkg);
    testSuites = lib.optionalAttrs lock.configuration.tests (
      lib.genAttrs p.testSuites (mkTestSuite pkg p)
    );
    benchmarks = lib.optionalAttrs lock.configuration.benchmarks (
      lib.genAttrs p.benchmarks (mkBenchmark pkg)
    );
  }) outputs;
in
{
  inherit project repository packages;
}
