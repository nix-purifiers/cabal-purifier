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
in
{
  inherit cli;

  # hello builds against random, async and unordered-containers from the
  # locked repository; unordered-containers comes with its Hackage
  # revision of the package description.
  fixture-app = runs "fixture-app-runs" "${app.packages.hello.executables.hello}/bin/hello" "hello purified";
}
