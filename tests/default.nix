# SPDX-License-Identifier: MIT
#
# The checks: sandboxed builds of the fixtures under fixtures/, from their
# committed lockfiles, and a run of what each build produced. Each
# fixture's cabal-purifier.lock.json is written by `cabal-purifier lock` in
# the fixture's directory; the external fixture keeps its lockfile outside
# it, under external/.
#
# The conformance checks are those of the nix-purifiers contract that the
# sandbox can run. The conformance checks of a stale, tampered, incomplete
# and malformed lockfile evaluate the library with nix-instantiate inside
# the build, so they see the error message and check that it names
# `cabal-purifier lock`. CI runs the conformance checks that need the
# network or Nix itself: conformance-relock, conformance-rebuild and
# conformance-offline.
#
# The real-world checks build a pinned upstream project from a lockfile
# under real-world/, which `cabal-purifier lock` wrote in a checkout of
# that project.
{
  pkgs,
  # lib.cabal-purifier.buildCabalProject of the flake.
  buildCabalProject,
  cli,
  # The source of ShellCheck v0.11.0 (tests/dependencies/flake.nix).
  shellcheck,
}:
let
  inherit (pkgs) lib;

  build = args: buildCabalProject ({ inherit pkgs; } // args);

  # Runs a program from a build and checks its output.
  runs =
    name: program: expected:
    pkgs.runCommand name { } ''
      output=$(${program})
      echo "$output"
      case "$output" in
        *${lib.escapeShellArg expected}*) ;;
        *) echo "${name}: expected ${expected}" >&2; exit 1 ;;
      esac
      touch "$out"
    '';

  app = build {
    src = ./fixtures/app;
    name = "fixture-app";
  };

  workspace = build {
    src = ./fixtures/workspace;
    name = "fixture-workspace";
    externalPaths."../shared-package" = ./fixtures/shared-package;
  };
  greeting = workspace.packages.greeting;

  external = build {
    src = ./fixtures/external;
    lockFile = ./external/cabal-purifier.lock.json;
    name = "fixture-external";
  };

  shellcheckProject = build {
    src = shellcheck;
    lockFile = ./real-world/shellcheck/cabal-purifier.lock.json;
    name = "shellcheck";
  };
  shellcheckPackage = shellcheckProject.packages.ShellCheck;

  # The lockfiles that the conformance checks give the library are the
  # lockfile of the app fixture, changed the ways a lockfile goes wrong.
  appLock = lib.importJSON ./fixtures/app/cabal-purifier.lock.json;
  lockText = name: lock: builtins.toFile "${name}.lock.json" (builtins.toJSON lock);
  # A changed lockfile with its hash made to match again, as for a
  # lockfile that `cabal-purifier lock` wrote incomplete.
  rehashed =
    lock:
    lock
    // {
      hash = builtins.convertHash {
        hash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "hash" ]));
        hashAlgo = "sha256";
        toHashFormat = "sri";
      };
    };
  withoutDownload =
    path: appLock // { downloads = builtins.filter (d: d.path != path) appLock.downloads; };

  # Evaluates readLock (read-lock.nix) of `lockFile` for the project
  # `project` in the build, and fails evaluation with its problems as
  # checkLock does. The check passes when the evaluation fails with a
  # message that holds `expected` and names `cabal-purifier lock`.
  lockFails =
    name:
    {
      lockFile,
      project ? ./fixtures/app,
      expected,
    }:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.nix ]; } ''
      export HOME="$TMPDIR" NIX_STATE_DIR="$TMPDIR/state"
      mkdir lib
      cp ${../nix/lib/read-lock.nix} lib/read-lock.nix
      cp ${../nix/lib/lock-version.nix} lib/lock-version.nix
      cp ${lockFile} lock.json
      cp -r ${project} project
      expression="let lock = import $PWD/lib/read-lock.nix { lockFile = $PWD/lock.json; src = $PWD/project; }; in
        if lock.problems == [ ] then lock.purifier else throw (builtins.concatStringsSep \"\n\" lock.problems)"
      if nix-instantiate --eval --store dummy:// --expr "$expression" 2> error; then
        echo "${name}: the lockfile evaluated" >&2
        exit 1
      fi
      cat error
      grep -qF ${lib.escapeShellArg expected} error
      grep -qF 'Run `cabal-purifier lock`' error
      touch "$out"
    '';
in
{
  inherit cli;

  # The unit tests of the lock run, the offline project copy and the plan
  # check (tests/unit).
  unit =
    pkgs.runCommand "unit-tests"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.darcs
        ];
        CABAL_PURIFIER_ROOT = ../.;
      }
      ''
        export HOME="$TMPDIR"
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
  # data-default-class from a package URL.
  fixture-workspace =
    runs "fixture-workspace-runs" "${workspace.packages.app.executables.greet}/bin/greet"
      "hello workspace";

  # The project's test run: the greeting library's test suite, run in a
  # copy of its package.
  fixture-workspace-tests = workspace.tests;

  fixture-workspace-bench =
    runs "fixture-workspace-bench" "${greeting.benchmarks.bench}/bin/bench"
      "8893";

  # The release that `cabal-purifier publish` uploads holds the source
  # tarball of each package, and the tarball holds the package description
  # and the library's module.
  fixture-workspace-release =
    pkgs.runCommand "fixture-workspace-release"
      {
        inherit (workspace) release;
        fetches = builtins.length workspace.fetches;
      }
      ''
        ls "$release"
        test -e "$release/app-0.1.0.tar.gz"
        files=$(tar -tzf "$release/greeting-0.2.0.tar.gz")
        echo "$files"
        echo "$files" | grep -qx greeting-0.2.0/greeting.cabal
        echo "$files" | grep -qx greeting-0.2.0/src/Greeting.hs
        test "$fetches" -gt 0
        touch "$out"
      '';

  # The documentation tarball for Hackage holds the module's page.
  fixture-workspace-docs =
    pkgs.runCommand "fixture-workspace-docs" { tarball = greeting.docs.tarball; }
      ''
        files=$(tar -tzf "$tarball")
        echo "$files" | grep -qx 'greeting-0.2.0-docs/Greeting.html'
        touch "$out"
      '';

  # The stale fixture is the app fixture with a changed hello.cabal, so the
  # lockfile of the app fixture is older than it.
  conformance-stale = lockFails "conformance-stale" {
    lockFile = ./fixtures/app/cabal-purifier.lock.json;
    project = ./fixtures/stale;
    expected = "hello.cabal changed since `cabal-purifier lock` wrote it";
  };

  # A lockfile whose content changed after the lock, and one whose hash
  # changed.
  conformance-tampered = pkgs.linkFarm "conformance-tampered" [
    {
      name = "content";
      path = lockFails "conformance-tampered-content" {
        lockFile = lockText "tampered-content" (
          appLock
          // {
            downloads = map (
              d: if d.path == "repository/random-1.3.1.tar.gz" then d // { url = "https://example.org/"; } else d
            ) appLock.downloads;
          }
        );
        expected = "does not match its hash";
      };
    }
    {
      name = "hash";
      path = lockFails "conformance-tampered-hash" {
        lockFile = lockText "tampered-hash" (
          appLock // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
        );
        expected = "does not match its hash";
      };
    }
  ];

  # A lockfile without the download of a package its plan uses.
  conformance-missing = lockFails "conformance-missing" {
    lockFile = lockText "missing" (rehashed (withoutDownload "repository/random-1.3.1.tar.gz"));
    expected = "uses random-1.3.1, which no locked source provides";
  };

  # A lockfile that is valid JSON but not a lockfile.
  conformance-malformed = lockFails "conformance-malformed" {
    lockFile = builtins.toFile "malformed.lock.json" (builtins.toJSON { version = 2; });
    expected = "it has no hash";
  };

  # The external fixture holds only Cabal's own files, and its lockfile is
  # kept outside it.
  conformance-external =
    assert !(builtins.pathExists ./fixtures/external/cabal-purifier.lock.json);
    runs "conformance-external" "${external.packages.external.executables.external}/bin/external"
      "hello external";

  # A system the lock has no plan for fails evaluation.
  negative-unknown-system =
    assert
      !(builtins.tryEval
        (build {
          src = ./fixtures/app;
          system = "riscv64-linux";
        }).project.drvPath
      ).success;
    pkgs.runCommand "negative-unknown-system" { } "touch $out";

  # ShellCheck v0.11.0, built against the 70 downloads its lockfile
  # records, reports its version and finds the unquoted expansion
  # (SC2086) in a script.
  real-world-shellcheck =
    pkgs.runCommand "real-world-shellcheck"
      {
        shellcheck = "${shellcheckPackage.executables.shellcheck}/bin/shellcheck";
      }
      ''
        "$shellcheck" --version | tee version
        grep -qx 'version: 0.11.0' version
        printf '#!/bin/sh\necho $1\n' > script.sh
        if "$shellcheck" script.sh > report; then
          echo "real-world-shellcheck: shellcheck found nothing in script.sh" >&2
          exit 1
        fi
        cat report
        grep -q SC2086 report
        touch "$out"
      '';

  # ShellCheck's own test suite.
  real-world-shellcheck-tests = shellcheckProject.tests;
}
