# cabal-purifier

A command and a Nix library that let Nix build a Cabal project offline, in
its sandbox. The command records the files Cabal wants to download in a
lockfile, and Nix builds the project from that lockfile. The project does
not need generated Nix files of its own.

cabal-purifier is part of [nix-purifiers](https://nix-purifiers.github.io).

- **A lockfile.** `cabal-purifier lock` writes `cabal-purifier.lock.json` at
  the project root. It holds every package tarball the plan uses, by URL
  and SHA-256, with each Hackage revision of a package description, and
  each source repository at its locked revision. It also holds the plan
  for x86_64-linux and for aarch64-linux, and the components of the
  project's own packages.
- **Sandboxed builds.** `buildCabalProject`, which the flake's overlay adds
  to a package set, turns a project and its lockfile into derivations, one
  for each output of the project: `packages.<package>.executables.<name>`,
  `testSuites.<name>`, `benchmarks.<name>`, `sdist` and `docs`. The
  lockfile names them, so Nix knows every output when it evaluates,
  without building anything first.
- **Offline Cabal during development.** `cabal-purifier cabal build` (or any
  other cabal command) runs cabal against the locked sources, which Nix
  fetches.
- **Publishing what Nix built.** `cabal-purifier publish <package>` builds the
  package's source tarball in the sandbox and uploads that file with
  `cabal upload`. With `--documentation`, it uploads the documentation
  tarball Nix built.

## How the lock is made

`cabal-purifier lock` runs `cabal update` in an empty Cabal directory, so
your own Cabal configuration does not apply, and then plans the project
with `cabal build all --dry-run`, with tests and benchmarks enabled. The
package index is the one thing it keeps between runs, in
`~/.cache/cabal-purifier` (or under `XDG_CACHE_HOME`), because Cabal
updates an index it already has in place: the first lock downloads all of
Hackage's index, and later ones take seconds. It
plans once for each system. Cabal takes the platform it plans for from
the compiler's `ghc --info`, so the command plans for the other system
through a GHC wrapper that reports that system and never compiles
anything. One machine therefore locks both systems.

From each plan (`plan.json`), the command records:

- each package from Hackage (or another package repository) with the
  tarball's SHA-256 that the plan gives. When Hackage holds a revision of
  the package description, the command finds its number in the package
  index and records the revision's own URL, `revision/<n>.cabal`, which
  never changes. The plan's `pkg-cabal-sha256` is that file's hash.
- each `source-repository-package` at its locked revision, with the hash
  of its checkout.
- each package URL in `packages:`, with the SHA-256 of its tarball.
- every package's version and flags, and which packages the compiler
  provides.
- the components of each package of the project: its library and
  sublibraries, executables, test suites, benchmarks and foreign
  libraries. These are the outputs of `buildCabalProject`.

The command then checks the lock: it fetches the locked sources through
Nix and plans the project again from those alone, and the plan must match
the lock.

`cabal-purifier lock` relocks only when `cabal.project`, its `.freeze` or
`.local` file, or a package's `.cabal` file changed. `cabal-purifier relock`
relocks regardless. `--no-tests` and `--no-benchmarks` lock a plan without
test suites or benchmarks, for a project whose test dependencies do not
resolve.

The lock run plans with the `ghc` on your `PATH`, or the compiler that
`with-compiler` names, and with the command's own GHC otherwise. Nix builds
with nixpkgs' GHC of the exact version the lock names.

The lockfile records the index state it planned with (`indexState`), and
`lock` and `relock` plan with that index state again. Adding a dependency
and locking therefore keeps every other package where it was, and a
relock reproduces the lockfile byte for byte. `--update` plans with the
newest index instead, which is how to upgrade dependencies. When a new
dependency is newer than the recorded index state, Cabal cannot plan it,
and the command says to run `cabal-purifier lock --update`. An
`index-state` in the project's own files takes precedence, and the
lockfile then records none.

## Use

In the project root:

```zsh
nix run github:nix-purifiers/cabal-purifier -- lock
```

Commit `cabal-purifier.lock.json`. The flake's `overlays.default` adds
`buildCabalProject` to a package set, and a package written for
`callPackage` takes it by name:

```nix
# package.nix
{ buildCabalProject, pkg-config, zlib }:
buildCabalProject {
  src = ./.;
  name = "my-project";
  # Libraries outside Cabal, such as zlib for `pkgconfig-depends: zlib`.
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ zlib ];
}
```

```nix
{
  inputs.cabal-purifier.url = "github:nix-purifiers/cabal-purifier";
  inputs.nixpkgs.follows = "cabal-purifier/nixpkgs";

  outputs = { nixpkgs, cabal-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ cabal-purifier.overlays.default ];
      };
      project = pkgs.callPackage ./package.nix { };
    in
    {
      packages.${system} = {
        default = project.packages.my-app.executables.my-app;
        sdist = project.packages.my-lib.sdist;
      };
      checks.${system}.spec = project.packages.my-lib.testSuites.spec;
    };
}
```

`buildCabalProject` returns:

- `project`, the build of every component of every package, by
  `cabal build all` against the locked plan. `doCheck = true` also runs
  `cabal test all` in it.
- `packages.<package>.executables.<name>`, each executable at
  `bin/<name>`.
- `packages.<package>.testSuites.<name>`, a run of each test suite in a
  copy of its package's directory.
- `packages.<package>.benchmarks.<name>`, each benchmark at `bin/<name>`.
- `packages.<package>.sdist`, the source tarball that `cabal sdist`
  makes; `sdist.tarball` names the file.
- `packages.<package>.docs`, the documentation tarball for Hackage from
  `cabal haddock --haddock-for-hackage`; `docs.tarball` names the file.
- `packages.<package>.library`, `sublibraries` and `foreignLibraries`,
  the package's library components as the lock records them.
- `repository`, the locked sources.

`nix/lib/build-cabal-project.nix` documents the builder's arguments:
`ghc` (the default is nixpkgs' GHC of the version the lock names),
`nativeBuildInputs` and `buildInputs` for libraries outside Cabal,
`doCheck`, `cabalFlags` for more arguments to every cabal command,
`fetchurl` and `fetchgit` for credentials or mirrors, `externalPaths` for
local packages outside the project, and `srcFilter`.

### How the build resolves offline

The builder makes a Cabal no-index repository (`file+noindex://`) of the
locked sources. It holds each package tarball, each Hackage revision of a
package description as `<name>-<version>.cabal` beside its tarball, and
each package from a source repository as a tarball packed from its
locked checkout. The build runs cabal with that repository as its only
repository, and with an offline copy of the project's configuration
(`nix/lib/offline_project.py`). The copy leaves out the
`source-repository-package` and `repository` sections and the
`index-state`, replaces each package URL with its unpacked directory, and
adds the lock's constraints, so Cabal resolves to the locked plan. After
the build, the builder compares Cabal's plan with the lock and fails on
any difference.

### Sources

Every kind of source that cabal-install fetches works:

- **Hackage and other package repositories**, with Hackage's revisions of
  package descriptions. A repository that needs credentials takes them
  through the builder's `fetchurl` argument.
- **Git source repositories** (`source-repository-package` with
  `type: git`), with their submodules, which Cabal checks out too. The Nix
  sandbox has no SSH keys, so a repository over SSH is locked at the HTTPS
  URL of the same host and path. A private repository takes a credentialed
  fetcher through the builder's `fetchgit` argument. The lock run itself
  uses your SSH keys and git credentials.
- **Mercurial and Darcs source repositories.** A Mercurial source needs a
  `tag`. A Darcs source without a `tag` is locked by the Darcs context of
  the checkout Cabal made in the lock run.
- **Pijul source repositories**, with a `tag`, fetched by nixpkgs'
  `fetchpijul`. The tests do not cover Pijul: Pijul fetches only from a
  Pijul server, such as the Nest, and the tests have none to serve a
  repository from.
- **Package URLs** in `packages:`.
- **Local packages inside the project**, which are the project's outputs,
  and **local tarballs and no-index repositories inside the project**.
- **Local packages outside the project**, such as `packages: ../shared`.
  The lock lists them as `externalPaths`, and the build takes each tree as
  an argument, keyed by the path the lock gives it:

  ```nix
  buildCabalProject {
    src = ./.;
    externalPaths."../shared" = inputs.shared;
  }
  ```

cabal-install refuses to sync Subversion, Bazaar and CVS source
repositories ("sync repo not yet supported"), so a project cannot use
them and there is nothing of those kinds to lock.

### Development

```zsh
nix run github:nix-purifiers/cabal-purifier -- cabal build
```

This fetches the locked sources through Nix into
`dist-newstyle/cabal-purifier/` and runs `cabal build` with a Cabal
directory whose only repository is the locked one, and with the offline
copy of the project's configuration. Arguments after `cabal` go to cabal,
so `cabal-purifier cabal run my-app` and `cabal-purifier cabal test` work
the same way. The command uses the `cabal` on your `PATH`, and its own
otherwise. The link `dist-newstyle/cabal-purifier/sources` is the GC root
that keeps the locked files in the store. The Cabal directory is the
command's own, so your `~/.config/cabal/config` does not apply and the
package store is under `dist-newstyle/cabal-purifier/cabal`. When the
lockfile is out of date, the command warns and runs cabal the usual way
until `cabal-purifier lock` renews it.

For an editor, and for every other tool that runs cabal itself, put the
command's `cabal` shim first on `PATH`:

```zsh
eval "$(nix run github:nix-purifiers/cabal-purifier -- env)"
```

Every `cabal` command then runs as `cabal-purifier cabal`, offline on the
locked sources. haskell-language-server, started from that shell or with
that `PATH`, loads the project through the shim: its build tool calls go
to the locked sources, and it needs a GHC on `PATH` as it always does. A
`.envrc` with that line does the same for direnv.

The lockfile is checked whenever the command or the Nix library reads it,
and each problem comes with the command that fixes it:

- a project file that changed since the lock: the command warns and runs
  cabal the usual way, and a Nix build fails, both saying to run
  `cabal-purifier lock`;
- a lockfile that is not valid JSON, or one whose downloads, repository
  files and plans do not match up: both say what is wrong and to run
  `cabal-purifier relock`;
- a download that no longer matches its hash: the command explains that
  the lockfile was edited or the source changed, and to run
  `cabal-purifier relock`;
- a build whose plan differs from the lock: the build lists the packages
  that differ.

### Publishing

```zsh
nix run github:nix-purifiers/cabal-purifier -- publish my-lib
nix run github:nix-purifiers/cabal-purifier -- publish my-lib --documentation
```

This builds `packages.my-lib.sdist` (or `.docs`) and uploads the file with
`cabal upload`, as a package candidate. Options after the package name go
to `cabal upload`, so `--publish` publishes the release, and credentials
work as they do for `cabal upload`.

## Limits

- **Libraries outside Cabal.** A `.cabal` file names system libraries
  (`extra-libraries`, `pkgconfig-depends`) but not where they come from,
  so the builder takes them as `nativeBuildInputs` and `buildInputs`.
- **Local packages given by absolute path.** A Nix build can create files
  only inside its own build directory, so it cannot put a tree at an
  absolute path. Paths relative to the project work.
- **Imports by URL in `cabal.project`.** Cabal fetches such an import while
  it reads the project, before any build step, so the offline copy cannot
  hold it, and the command explains this. Imports of local files work.
- **Your own Cabal configuration.** The lock run and the builds use an
  empty Cabal directory, so settings in `~/.config/cabal/config` do not
  apply. Settings in `cabal.project` do.

## Credit

cabal-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): a lock run
with empty caches that records every download, a builder that runs the
tool itself in the sandbox from that lockfile, an offline interactive mode
on the same locked files, and publishing what Nix built. nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo) inspired the
nix-purifiers family.

## Tests

`nix flake check` runs the unit tests (`tests/unit`: the lock run's
parsing of plans, package indexes and lockfiles, its URL and path logic,
the offline project copy and the plan check). It builds the fixtures
under `tests/fixtures` in the sandbox and runs each: an app on Hackage
packages, one of them with a Hackage revision, and a workspace with a
library, its test suite and benchmark, an executable, a git source
repository, a package URL and a local package outside the project. The
checks also inspect the source and documentation tarballs. Negative
checks give the builder a stale lockfile, one with a missing download,
one whose plan names a package no source provides, and a system the lock
has no plan for, and each must fail.

`tests/interactive.sh` tests what runs outside the sandbox. It relocks
each fixture and compares the result with the committed lockfile, byte
for byte. It builds and runs the workspace with `cabal-purifier cabal`
with every proxy pointed at a closed port, adds a dependency and locks,
and checks the errors for a stale, a malformed, an inconsistent and a
tampered lockfile. It also publishes to a stand-in Hackage
(`tests/fake_hackage.py`) and compares the uploaded bytes with the tarball
Nix built. `tests/vcs.sh` serves a Mercurial repository and two Darcs
repositories on 127.0.0.1, locks a project that takes all three, and
builds and runs it with Nix. `tests/editor.sh` runs
haskell-language-server on the workspace through the `cabal-purifier env`
shim, with every proxy pointed at a closed port. CI runs all of them on
x86_64-linux and aarch64-linux.

## License

MIT
