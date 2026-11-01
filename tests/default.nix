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
in
{
  inherit cli;

  # hello builds against random, async and unordered-containers from the
  # locked repository; unordered-containers comes with its Hackage
  # revision of the package description.
  fixture-app = runs "fixture-app-runs" "${app.packages.hello.executables.hello}/bin/hello" "hello purified";

  # greet builds against the project's own library, a local package
  # outside the project, tagged from its git source repository and
  # data-default-class from a package URL. The `project` build runs the
  # test suite (doCheck).
  fixture-workspace = runs "fixture-workspace-runs" "${workspace.packages.app.executables.greet}/bin/greet" "hello workspace";

  # The test suite as its own output, run in a copy of its package.
  fixture-workspace-test = greeting.testSuites.spec;

  fixture-workspace-bench = runs "fixture-workspace-bench" "${greeting.benchmarks.bench}/bin/bench" "8893";

  # The source tarball `cabal upload` publishes holds the package
  # description and the library's module.
  fixture-workspace-sdist =
    purified.runCommand "fixture-workspace-sdist" { tarball = greeting.sdist.tarball; } ''
      files=$(tar -tzf "$tarball")
      echo "$files"
      echo "$files" | grep -qx greeting-0.2.0/greeting.cabal
      echo "$files" | grep -qx greeting-0.2.0/src/Greeting.hs
      touch "$out"
    '';

  # The documentation tarball for Hackage holds the module's page.
  fixture-workspace-docs =
    purified.runCommand "fixture-workspace-docs" { tarball = greeting.docs.tarball; } ''
      files=$(tar -tzf "$tarball")
      echo "$files" | grep -qx 'greeting-0.2.0-docs/Greeting.html'
      touch "$out"
    '';
}
