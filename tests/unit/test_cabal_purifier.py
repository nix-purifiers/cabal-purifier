# SPDX-License-Identifier: MIT
"""Unit tests for the lock run's parsing and its URL and path logic
(bin/cabal-purifier), the offline copy of a project's configuration
(nix/lib/offline_project.py) and the plan check (nix/lib/check_plan.py).

Run them from the repository root with `python3 -m unittest discover -s
tests/unit`. The flake's `unit` check runs them in the sandbox."""

import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(os.environ.get("CABAL_PURIFIER_ROOT", Path(__file__).resolve().parents[2]))


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


os.environ.setdefault("CABAL_PURIFIER_LIB", str(ROOT / "nix/lib"))
cli = load("cabal_purifier", ROOT / "bin/cabal-purifier")
offline = load("offline_project", ROOT / "nix/lib/offline_project.py")
check_plan = load("check_plan", ROOT / "nix/lib/check_plan.py")


class LocalCompilerTest(unittest.TestCase):
    def validate(self, version="99.7.1", target="x86_64-unknown-linux", package_version=None, arguments=()):
        # A version absent from any packaged SDK catalog is still valid locally.
        lock = {"systems": {"x86_64-linux": {"compiler": "ghc-99.7.1"}}}
        def output(argv, **kwargs):
            if argv[-1] == "--numeric-version":
                return version
            if argv[-1] == "--info":
                return '[("Target platform","' + target + '")]'
            if argv[-1] == "--version":
                return "GHC package manager version " + (package_version or version)
            self.fail(argv)
        with patch.object(cli, "find_compiler", return_value=Path("/opt/user-ghc/bin/ghc")) as default_compiler, patch.object(cli, "ghc_pkg_for", return_value=Path("/opt/user-ghc/bin/ghc-pkg")), patch.object(cli, "host_system", return_value="x86_64-linux"), patch.object(cli, "run", side_effect=output):
            result = cli.validate_local_compiler(Path("."), lock, arguments)
            if arguments:
                default_compiler.assert_not_called()
            return result

    def test_noncatalog_host_compiler(self):
        self.assertEqual(self.validate(), Path("/opt/user-ghc/bin/ghc"))

    def test_explicit_compiler_without_default(self):
        with patch.object(cli.shutil, "which", return_value="/opt/explicit-ghc/bin/ghc"):
            self.assertEqual(self.validate(arguments=("build", "--with-compiler=/opt/explicit-ghc/bin/ghc")), Path("/opt/explicit-ghc/bin/ghc"))

    def test_attached_short_compiler(self):
        with patch.object(cli.shutil, "which", return_value="/opt/attached-ghc/bin/ghc"):
            self.assertEqual(self.validate(arguments=("build", "-w/opt/attached-ghc/bin/ghc")), Path("/opt/attached-ghc/bin/ghc"))

    def test_compiler_in_cabal_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "native-config"
            config.write_text('with-compiler: "/opt/host sdk/bin/ghc"\n')
            with patch.dict(os.environ, CABAL_CONFIG=str(config)), patch.object(cli.shutil, "which", side_effect=lambda name: name):
                self.assertEqual(cli.find_compiler(root), Path("/opt/host sdk/bin/ghc"))
                (root / "cabal.project").write_text("with-compiler: /opt/project-ghc\n")
                self.assertEqual(cli.find_compiler(root), Path("/opt/project-ghc"))

    def test_executable_arguments_do_not_select_compiler(self):
        self.assertEqual(cli.compiler_arguments(["run", "hello", "--", "-wapp-option"]), (None, None, ["run", "hello", "--", "-wapp-option"]))

    def test_global_config_is_consumed_after_sdk_selection(self):
        self.assertEqual(cli.compiler_arguments(["--config-file", "/opt/config", "build", "-w/opt/ghc"]), ("/opt/ghc", "/opt/config", ["build", "-w/opt/ghc"]))

    def test_relative_path_is_anchored_without_resolving_sdk_symlinks(self):
        with patch.dict(os.environ, PATH="sdk/bin::/usr/bin"), patch("os.getcwd", return_value="/caller"):
            self.assertEqual(cli.local_environment()["PATH"], "/caller/sdk/bin:/caller:/usr/bin")
            with patch.object(cli.shutil, "which", return_value="sdk/bin/ghc"):
                self.assertEqual(self.validate(arguments=("build", "-wsdk/bin/ghc")), Path("/caller/sdk/bin/ghc"))

    def test_wrong_version(self):
        with self.assertRaisesRegex(cli.Failure, "lock names ghc-99.7.1"):
            self.validate(version="99.7.2")

    def test_wrong_target(self):
        with self.assertRaisesRegex(cli.Failure, "local development runs on x86_64-linux"):
            self.validate(target="aarch64-apple-darwin")

    def test_wrong_package_tool(self):
        with self.assertRaisesRegex(cli.Failure, "belongs to GHC 98.1"):
            self.validate(package_version="98.1")

    def test_prefetch_preserves_runtime_path(self):
        with tempfile.TemporaryDirectory(prefix="host sdk ") as temporary:
            root = Path(temporary)
            calls = []
            def output(argv, **kwargs):
                calls.append(argv)
                return "/nix/store/locked-dependencies\n"
            with patch.object(cli, "read_current_lock", return_value={}), patch.object(cli, "validate_local_compiler") as selected, patch.object(cli, "real_cabal", return_value="/opt/user-cabal/bin/cabal"), patch.object(cli, "host_system", return_value="x86_64-linux"), patch.object(cli, "purifier_source", return_value="/source/purifier"), patch.object(cli, "run", side_effect=output), patch.dict(os.environ, CABAL_PURIFIER_SELF="/opt/user tools/cabal-purifier"), patch("sys.stdout", new_callable=io.StringIO) as stdout:
                cli.verb_prefetch(root, root / cli.LOCK_NAME, None, [])
            selected.assert_called_once()
            self.assertEqual(calls[0][calls[0].index("withToolchain") + 1], "false")
            self.assertNotIn("toolchain/bin", stdout.getvalue())
            self.assertFalse((cli.work_dir(root) / "toolchain").exists())
            # Verify shell quoting even when the project and executable contain spaces.
            subprocess.run(["sh", "-n", str(cli.work_dir(root) / "bin/cabal")], check=True)


class HttpsTest(unittest.TestCase):
    def test_scp_style_url(self):
        self.assertEqual(cli.https("git@github.com:owner/repo.git"), "https://github.com/owner/repo.git")

    def test_ssh_url_with_user_and_port(self):
        self.assertEqual(
            cli.https("ssh://git@gitlab.example.org:2222/group/repo.git"),
            "https://gitlab.example.org/group/repo.git",
        )

    def test_https_url_is_unchanged(self):
        self.assertEqual(cli.https("https://github.com/owner/repo"), "https://github.com/owner/repo")


class HashTest(unittest.TestCase):
    def test_sri_from_hex(self):
        digest = hashlib.sha256(b"cabal").hexdigest()
        self.assertEqual(
            cli.sri_from_hex(digest), "sha256-" + __import__("base64").b64encode(bytes.fromhex(digest)).decode()
        )

    def test_source_path_is_deterministic_and_distinguishes_its_parts(self):
        a = cli.source_path("hg", "http://host/repo", "abc")
        self.assertEqual(a, cli.source_path("hg", "http://host/repo", "abc"))
        self.assertNotEqual(a, cli.source_path("hg", "http://host/repo", "abd"))
        self.assertTrue(a.startswith("source/hg-"))


class ComponentsTest(unittest.TestCase):
    def test_per_component_units(self):
        units = [
            {"component-name": "lib"},
            {"component-name": "lib:internal"},
            {"component-name": "exe:tool"},
            {"component-name": "test:spec"},
            {"component-name": "bench:speed"},
            {"component-name": "flib:ffi"},
            {"component-name": "setup"},
        ]
        self.assertEqual(
            cli.components_of(units),
            {
                "library": True,
                "sublibraries": ["internal"],
                "executables": ["tool"],
                "testSuites": ["spec"],
                "benchmarks": ["speed"],
                "foreignLibraries": ["ffi"],
            },
        )

    def test_custom_setup_unit_lists_its_components(self):
        units = [{"components": {"lib": {}, "exe:tool": {}, "setup": {}}}]
        components = cli.components_of(units)
        self.assertTrue(components["library"])
        self.assertEqual(components["executables"], ["tool"])


class ConstraintsTest(unittest.TestCase):
    def test_constraints(self):
        units = [
            {"name": "base", "version": "4.20.2.0", "flags": {}, "installed": True, "local": False},
            {"name": "async", "version": "2.2.6", "flags": {"bench": False, "debug": True}, "installed": False, "local": False},
            {"name": "random", "version": "1.3.1", "flags": {}, "installed": False, "local": False},
        ]
        self.assertEqual(
            cli.constraints_of(units),
            [
                "any.base installed",
                "any.async ==2.2.6",
                "any.async -bench +debug",
                "any.random ==1.3.1",
            ],
        )


class RevisionsTest(unittest.TestCase):
    """index_revisions picks the index entry whose hash the plan used,
    which need not be the newest one."""

    def index(self, directory, entries):
        repo = Path(directory) / "hackage.haskell.org"
        repo.mkdir()
        with tarfile.open(repo / "01-index.tar", "w") as tar:
            for name, text in entries:
                info = tarfile.TarInfo(name)
                info.size = len(text)
                tar.addfile(info, io.BytesIO(text))

    def test_revision_the_plan_used(self):
        original = b"name: pkg\nversion: 1.0\n"
        first = b"name: pkg\nversion: 1.0\nx-revision: 1\n"
        second = b"name: pkg\nversion: 1.0\nx-revision: 2\n"
        with tempfile.TemporaryDirectory() as tmp:
            self.index(tmp, [("pkg/1.0/pkg.cabal", t) for t in (original, first, second)])
            for text, revision in ((original, 0), (first, 1), (second, 2)):
                wanted = {("pkg", "1.0"): hashlib.sha256(text).hexdigest()}
                self.assertEqual(cli.index_revisions(tmp, wanted), {("pkg", "1.0"): revision})

    def test_missing_description(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.index(tmp, [("other/1.0/other.cabal", b"name: other\n")])
            self.assertEqual(cli.index_revisions(tmp, {("pkg", "1.0"): "00"}), {})


class LockProblemsTest(unittest.TestCase):
    def lock(self):
        return {
            "downloads": [
                {"path": "repository/a-1.tar.gz"},
                {"path": "remote/x"},
                {"path": "source/git-b"},
            ],
            "repository": [{"file": "b-3.tar.gz", "pack": {"from": "source/git-b", "subdir": ".", "root": "b-3"}}],
            "remotePackages": [{"uri": "https://e/x.tar.gz", "from": "remote/x", "package": "x-2"}],
            "systems": {
                "x86_64-linux": {
                    "units": [
                        {"name": "a", "version": "1", "installed": False, "local": False},
                        {"name": "x", "version": "2", "installed": False, "local": False},
                        {"name": "b", "version": "3", "installed": False, "local": False},
                        {"name": "base", "version": "4", "installed": True, "local": False},
                        {"name": "me", "version": "0", "installed": False, "local": True},
                    ]
                }
            },
        }

    def test_consistent_lock(self):
        self.assertEqual(cli.lock_problems(self.lock()), [])

    def test_missing_pack_download(self):
        lock = self.lock()
        lock["downloads"] = [d for d in lock["downloads"] if d["path"] != "source/git-b"]
        self.assertEqual(
            cli.lock_problems(lock),
            ["the repository file b-3.tar.gz names no download source/git-b"],
        )

    def test_unit_without_source(self):
        lock = self.lock()
        lock["downloads"] = [d for d in lock["downloads"] if d["path"] != "repository/a-1.tar.gz"]
        self.assertIn(
            "the plan for x86_64-linux uses a-1, which no locked source provides",
            cli.lock_problems(lock),
        )


class ReadLockTest(unittest.TestCase):
    def read(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / cli.LOCK_NAME
            path.write_text(text)
            return cli.read_lock(path)

    def valid(self):
        lock = {key: [] for key in cli.SECTIONS}
        lock.update(version=cli.LOCK_VERSION, configuration={}, definition={}, systems={}, outputs={})
        lock["hash"] = cli.content_hash(lock)
        return lock

    def test_valid(self):
        self.assertEqual(self.read(json.dumps(self.valid()))["version"], cli.LOCK_VERSION)

    def test_malformed_json(self):
        with self.assertRaisesRegex(cli.Failure, "not valid JSON.*cabal-purifier lock"):
            self.read("{ not json")

    def test_other_version(self):
        with self.assertRaisesRegex(cli.Failure, "version 99.*cabal-purifier lock"):
            self.read(json.dumps({"version": 99}))

    def test_missing_section(self):
        with self.assertRaisesRegex(cli.Failure, "damaged: it has no hash.*cabal-purifier lock"):
            self.read(json.dumps({"version": cli.LOCK_VERSION, "configuration": {}}))

    def test_tampered(self):
        lock = self.valid()
        lock["externalPaths"] = ["../elsewhere"]
        with self.assertRaisesRegex(cli.Failure, "does not match its hash.*cabal-purifier lock"):
            self.read(json.dumps(lock))


class OfflineProjectTest(unittest.TestCase):
    PROJECT = """packages:
  app
  https://example.org/pkg-1.0.tar.gz

index-state: 2026-01-01T00:00:00Z
active-repositories: hackage.haskell.org

source-repository-package
  type: git
  location: https://github.com/owner/repo.git
  tag: abc

repository private
  url: https://packages.example.org/

package app
  ghc-options: -Wall

-- a comment stays
tests: True
"""

    def write(self, files, remote=None, constraints=()):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        project = Path(tmp.name) / "project"
        project.mkdir()
        for name, text in files.items():
            (project / name).parent.mkdir(parents=True, exist_ok=True)
            (project / name).write_text(text)
        out = Path(tmp.name) / "out"
        main = offline.write(project, out, remote or {}, constraints)
        return main.read_text(), out

    def test_rewrite(self):
        text, _ = self.write(
            {"cabal.project": self.PROJECT},
            remote={"https://example.org/pkg-1.0.tar.gz": "/store/remote/0"},
            constraints=["any.pkg ==1.0"],
        )
        self.assertNotIn("source-repository-package", text)
        self.assertNotIn("repository private", text)
        self.assertNotIn("index-state", text)
        self.assertNotIn("active-repositories", text)
        self.assertIn("/store/remote/0", text)
        self.assertNotIn("https://example.org", text)
        self.assertIn("package app\n  ghc-options: -Wall", text)
        self.assertIn("-- a comment stays", text)
        self.assertIn("tests: True", text)
        self.assertTrue(text.rstrip().endswith("constraints:\n  any.pkg ==1.0"))

    def test_implicit_project(self):
        text, _ = self.write({"pkg.cabal": "name: pkg\n"})
        self.assertEqual(text, "packages: ./*.cabal\n")

    def test_companion_files(self):
        _, out = self.write(
            {
                "cabal.project": "packages: .\n",
                "cabal.project.freeze": "index-state: 2026-01-01T00:00:00Z\nconstraints: any.a ==1\n",
            }
        )
        self.assertEqual((out / "cabal.project.freeze").read_text(), "constraints: any.a ==1\n")
        self.assertFalse((out / "cabal.project.local").exists())

    def test_import_is_inlined(self):
        text, _ = self.write(
            {
                "cabal.project": "packages: .\nimport: config/common.project\n",
                "config/common.project": "index-state: 2026-01-01T00:00:00Z\nghc-options: -O2\n",
            }
        )
        self.assertIn("ghc-options: -O2", text)
        self.assertNotIn("index-state", text)
        self.assertNotIn("import:", text)

    def test_import_by_url_is_refused(self):
        with self.assertRaisesRegex(offline.ProjectError, "import by URL"):
            self.write({"cabal.project": "import: https://example.org/stackage.config\n"})


class CheckPlanTest(unittest.TestCase):
    def run_check(self, plan_units, lock_units):
        with tempfile.TemporaryDirectory() as tmp:
            plan = Path(tmp) / "plan.json"
            units = Path(tmp) / "units.json"
            plan.write_text(json.dumps({"install-plan": plan_units}))
            units.write_text(json.dumps(lock_units))
            stderr = io.StringIO()
            old, sys.stderr = sys.stderr, stderr
            try:
                return check_plan.main(plan, units), stderr.getvalue()
            finally:
                sys.stderr = old

    PLAN = [
        {"type": "configured", "pkg-name": "a", "pkg-version": "1", "style": "global", "flags": {"f": True}},
        {"type": "configured", "pkg-name": "x", "pkg-version": "2", "style": "local", "flags": {}},
        {"type": "pre-existing", "pkg-name": "base", "pkg-version": "4"},
    ]
    LOCK = [
        {"name": "a", "version": "1", "flags": {"f": True}, "installed": False, "local": False},
        {"name": "x", "version": "2", "flags": {}, "installed": False, "local": False},
        {"name": "base", "version": "4", "flags": {}, "installed": True, "local": False},
    ]

    def test_matching_plan_ignores_local_style(self):
        self.assertEqual(self.run_check(self.PLAN, self.LOCK)[0], 0)

    def test_other_version(self):
        plan = [dict(self.PLAN[0], **{"pkg-version": "1.1"})] + self.PLAN[1:]
        code, message = self.run_check(plan, self.LOCK)
        self.assertEqual(code, 1)
        self.assertIn("locked: a-1", message)
        self.assertIn("built:  a-1.1", message)
        self.assertIn("relock", message)

    def test_other_flags(self):
        plan = [dict(self.PLAN[0], flags={"f": False})] + self.PLAN[1:]
        self.assertEqual(self.run_check(plan, self.LOCK)[0], 1)


@unittest.skipUnless(shutil.which("darcs"), "needs darcs")
class DarcsContextTest(unittest.TestCase):
    """Cabal names a checkout after the repository, so the lock run finds
    the Darcs checkout of a source by the location it was cloned from."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        (self.origin / "A.hs").write_text("module A where\n")
        subprocess.run(["darcs", "init", "-q", "--repodir", str(self.origin)], check=True)
        subprocess.run(
            ["darcs", "record", "--repodir", str(self.origin), "-q", "-a", "-l", "-A", "tester", "-m", "init"],
            check=True,
        )
        self.src = self.tmp / "src"
        self.src.mkdir()
        (self.src / "other-1234").mkdir()
        subprocess.run(["darcs", "clone", "-q", str(self.origin), str(self.src / "origin-5678")], check=True)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_finds_the_checkout_of_the_location(self):
        checkouts = sorted(self.src.iterdir())
        context = cli.darcs_context(checkouts, str(self.origin))
        self.assertIn("init", context)

    def test_other_location_is_refused(self):
        checkouts = sorted(self.src.iterdir())
        with self.assertRaises(cli.Failure):
            cli.darcs_context(checkouts, str(self.tmp / "elsewhere"))



class InstalledWrapperTest(unittest.TestCase):
    def test_unlocked_wrapper_skips_its_own_profile_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            own = root / "package" / "bin"
            profile = root / "profile" / "bin"
            stock = root / "stock"
            for path in (own, profile, stock):
                path.mkdir(parents=True)
            (own / "cabal").write_text("#!/bin/sh\nexit 99\n")
            (own / "cabal").chmod(0o755)
            (profile / "cabal").symlink_to(own / "cabal")
            native = stock / "cabal"
            native.write_text(
                "#!" + sys.executable + "\n"
                "import json, sys\nprint(json.dumps(sys.argv[1:]))\nsys.exit(23)\n"
            )
            native.chmod(0o755)
            args = ["build", "argument with spaces", "--example=a=b"]
            env = dict(os.environ, CABAL_PURIFIER_SHIM="1", CABAL_PURIFIER_SELF=str(own / "cabal-purifier"))
            env["PATH"] = os.pathsep.join([str(profile), str(stock), env.get("PATH", "")])
            result = subprocess.run(
                [sys.executable, str(ROOT / "bin/cabal-purifier"), *args],
                cwd=root, env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertEqual(json.loads(result.stdout), args)
            self.assertIn("warning:", result.stderr)
            self.assertIn("impurely", result.stderr)

if __name__ == "__main__":
    unittest.main()
