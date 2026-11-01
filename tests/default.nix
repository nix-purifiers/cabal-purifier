# SPDX-License-Identifier: MIT
#
# The checks: sandboxed builds of the fixtures under fixtures/, from their
# committed lockfiles, and a run of what each build produced. Each
# fixture's cabal-purifier.lock.json is written by `cabal-purifier lock` in
# the fixture's directory. tests/interactive.sh covers what runs outside
# the sandbox: the lock run, `cabal` and `publish`.
{
  pkgs,
  overlay,
  cli,
}:
let
  purified = pkgs.extend overlay;
  inherit (purified) lib;

  # Runs a program from a build and checks its output.
  runs =
    name: program: expected:
    purified.runCommand name { } ''
      output=$(${program})
      echo "$output"
      case "$output" in
        *${lib.escapeShellArg expected}*) ;;
        *) echo "${name}: expected ${expected}" >&2; exit 1 ;;
      esac
      touch "$out"
    '';

  app = purified.buildCabalProject {
    src = ./fixtures/app;
    name = "fixture-app";
  };

  workspace = purified.buildCabalProject {
    src = ./fixtures/workspace;
    name = "fixture-workspace";
    externalPaths."../shared-package" = ./fixtures/shared-package;
    doCheck = true;
  };
  greeting = workspace.packages.greeting;

  # The negative checks: the app fixture with a lockfile changed the ways
  # a stale or damaged lockfile is wrong. Each must fail to evaluate, with
  # the library's message, before anything builds.
  appLock = lib.importJSON ./fixtures/app/cabal-purifier.lock.json;
  withLock =
    name: lock: args:
    purified.buildCabalProject (
      {
        src = ./fixtures/app;
        lockFile = builtins.toFile "${name}.lock.json" (builtins.toJSON lock);
      }
      // args
    );
  evaluationFails =
    name: build:
    assert !(builtins.tryEval build.project.drvPath).success;
    purified.runCommand name { } "touch $out";
  withoutDownload =
    path: appLock // { downloads = builtins.filter (d: d.path != path) appLock.downloads; };
  withoutRepositoryFile =
    file: appLock // { repository = builtins.filter (f: f.file != file) appLock.repository; };
in
{
  inherit cli;

  # The unit tests of the lock run, the offline project copy and the plan
  # check (tests/unit).
  unit =
    purified.runCommand "unit-tests"
      {
        nativeBuildInputs = [ purified.python3 ];
        CABAL_PURIFIER_ROOT = ../.;
      }
      ''
        python3 -m unittest discover -v -s ${./unit}
        touch "$out"
      '';

  # hello builds against random, async and unordered-containers from the
  # locked repository; unordered-containers comes with its Hackage
  # revision of the package description.
  fixture-app =
    runs "fixture-app-runs" "${app.packages.hello.executables.hello}/bin/hello"
      "hello purified";

  # greet builds against the project's own library, a local package
  # outside the project, tagged from its git source repository and
  # data-default-class from a package URL. The `project` build runs the
  # test suite (doCheck).
  fixture-workspace =
    runs "fixture-workspace-runs" "${workspace.packages.app.executables.greet}/bin/greet"
      "hello workspace";

  # The test suite as its own output, run in a copy of its package.
  fixture-workspace-test = greeting.testSuites.spec;

  fixture-workspace-bench =
    runs "fixture-workspace-bench" "${greeting.benchmarks.bench}/bin/bench"
      "8893";

  # The source tarball `cabal upload` publishes holds the package
  # description and the library's module.
  fixture-workspace-sdist =
    purified.runCommand "fixture-workspace-sdist" { tarball = greeting.sdist.tarball; }
      ''
        files=$(tar -tzf "$tarball")
        echo "$files"
        echo "$files" | grep -qx greeting-0.2.0/greeting.cabal
        echo "$files" | grep -qx greeting-0.2.0/src/Greeting.hs
        touch "$out"
      '';

  # The control for the negative checks: the unchanged lockfile, passed
  # the same way, evaluates.
  negative-control =
    assert (builtins.tryEval (withLock "unchanged" appLock { }).project.drvPath).success;
    purified.runCommand "negative-control" { } "touch $out";

  # A package description that changed since the lock.
  negative-stale-lock = evaluationFails "negative-stale-lock" (
    withLock "stale" (
      appLock
      // {
        definition = appLock.definition // {
          "hello.cabal" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      }
    ) { }
  );

  # A repository file that names a download the lock does not hold.
  negative-missing-download = evaluationFails "negative-missing-download" (
    withLock "missing-download" (withoutDownload "repository/random-1.3.1.tar.gz") { }
  );

  # A package of the plan that no locked source provides.
  negative-missing-source = evaluationFails "negative-missing-source" (
    withLock "missing-source" (withoutRepositoryFile "random-1.3.1.tar.gz") { }
  );

  # A system the lock has no plan for.
  negative-unknown-system = evaluationFails "negative-unknown-system" (
    withLock "unknown-system" appLock { system = "riscv64-linux"; }
  );

  # The documentation tarball for Hackage holds the module's page.
  fixture-workspace-docs =
    purified.runCommand "fixture-workspace-docs" { tarball = greeting.docs.tarball; }
      ''
        files=$(tar -tzf "$tarball")
        echo "$files" | grep -qx 'greeting-0.2.0-docs/Greeting.html'
        touch "$out"
      '';
}
