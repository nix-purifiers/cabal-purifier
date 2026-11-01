# cabal-purifier

A command and a Nix library that let Nix build a Cabal project offline, in
its sandbox. The command records the files Cabal wants to download in a
lockfile, and Nix builds the project from that lockfile. The project does
not need generated Nix files of its own.

cabal-purifier is part of [nix-purifiers](https://nix-purifiers.github.io).
It meets the [purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)
that every nix-purifier meets.

## Quickstart

In the project root, which has a `cabal.project` or a `.cabal` file:

```zsh
nix run github:nix-purifiers/cabal-purifier -- lock
```

This writes `cabal-purifier.lock.json`. Commit it. The overlay of the
flake, `overlays.default`, adds `buildCabalProject` to a package set, and a
package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildCabalProject, pkg-config, zlib }:
buildCabalProject {
  src = ./.;
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
        release = project.release;
      };
      checks.${system}.tests = project.tests;
    };
}
```

`buildCabalProject` returns these attributes, and Nix knows every name
when it evaluates, without building anything:

- `packages.<package>`, for each package of the project:
  - `executables.<name>`, each executable at `bin/<name>`;
  - `testSuites.<name>`, a run of each test suite in a copy of the
    package directory;
  - `benchmarks.<name>`, each benchmark at `bin/<name>`;
  - `sdist`, the source tarball that `cabal sdist` makes, and `docs`, the
    documentation tarball for Hackage from
    `cabal haddock --haddock-for-hackage`; `.tarball` names the file of
    each;
  - `library`, `sublibraries` and `foreignLibraries`, the library
    components as the lock records them.
- `tests`, the run of every test suite of the project.
- `release`, a directory with the source tarball of each package, the
  files that `cabal-purifier publish` uploads.
- `fetches`, the entries of the
  [purifier library](https://github.com/nix-purifiers/purifier) that the
  build fetches, for SBOM, license and vulnerability tools.
- `project`, the build of every component of every package, by
  `cabal build all` against the locked plan, and `repository`, the locked
  sources.

The builder also takes `ghc` (the default is the nixpkgs GHC of the
version the lock names), `cabalFlags` for more arguments to every cabal
command, `srcFilter`, `externalPaths` for local packages outside the
project (see [Supported language repositories](#supported-language-repositories)),
and `fetchers`. A company mirror or credentials go into
`fetchers.fetchurl` (and `fetchers.fetchgit` for a private git
repository), which the purifier library's `fetchEntry` calls with the
arguments of the nixpkgs fetcher of that name.

### A lockfile outside the project

A flake that packages a project whose author does not change it keeps the
lockfile outside the project tree and passes it as `lockFile`:

```nix
pkgs.buildCabalProject {
  src = inputs.some-project;
  lockFile = ./locks/some-project.lock.json;
}
```

A `lockFile` outside `src` takes the place of any lockfile in it. Every
command takes `--lockfile <path>`, or the environment variable
`CABAL_PURIFIER_LOCKFILE`, for such a lockfile, and either one takes
precedence over the default, `cabal-purifier.lock.json` at the project
root. The dev shell of the flake can set the variable to the same path, so
that a developer runs the commands with no flag.

## Development loop

```zsh
eval "$(nix run github:nix-purifiers/cabal-purifier -- prefetch)"
cabal build
cabal test
```

`prefetch` (see [Working offline](#working-offline)) puts a `cabal` shim first
on `PATH`. The shim runs cabal against the locked sources, so the
everyday commands are cabal commands: `cabal build`, `cabal run my-app`
and `cabal test`. When a project file changed since the lock, the shim
exits with an error that says to run `cabal-purifier lock`.

To lock after a change, or to move dependencies:

- `cabal-purifier lock` records the resolution that Cabal makes, as it is. The plan
  uses the package index as of the last lock, so adding a dependency
  keeps every other package where it was, and locking an unchanged
  project writes the same file byte for byte. A `cabal.project.freeze`
  stays as it is.
- `cabal-purifier update [<package>...]` re-resolves the named packages,
  or every package, with the newest package index, writes
  `cabal.project.freeze` again when the project has one, and then locks.
  Afterwards both files pass the staleness check.
- `cabal-purifier publish <package> [--documentation]` uploads what Nix
  built: the source tarball of the package, taken from `release`, or with
  `--documentation` its documentation tarball, with `cabal upload` as a
  package candidate. Options after the package name go to `cabal upload`,
  so `--publish` publishes the release, and credentials work as they do
  for `cabal upload`.

`--no-tests` and `--no-benchmarks` lock a plan without test suites or
benchmarks, for a project whose test dependencies do not resolve.

### How the lock is made

`cabal-purifier lock` runs `cabal update` in an empty Cabal directory, so
your own Cabal configuration does not apply, and then plans the project
with `cabal build all --dry-run`, with tests and benchmarks enabled. The
package index is the one thing it keeps between runs, in
`~/.cache/cabal-purifier` (or under `XDG_CACHE_HOME`), because Cabal
updates an index it already has in place: the first lock downloads the
whole Hackage index, and later ones take seconds. The command plans once for
each system. Cabal takes the platform it plans for from the output of
`ghc --info`, so the command plans for the other system through a GHC
wrapper that reports that system and never compiles anything. One machine
therefore locks both systems.

The lock run plans with the `ghc` on your `PATH`, or the compiler that
`with-compiler` names, and with a GHC that the command brings along
otherwise. Nix
builds with the nixpkgs GHC of the exact version the lock names.

From each plan (`plan.json`), the command records:

- each package from Hackage (or another package repository) with the
  SHA-256 of the tarball that the plan gives. When Hackage holds a
  revision of the package description, the command finds its number in
  the package index and records the URL of that revision,
  `revision/<n>.cabal`, which never changes. The `pkg-cabal-sha256` of
  the plan is the hash of that file.
- each `source-repository-package` at its locked revision, with the hash
  of its checkout.
- each package URL in `packages:`, with the SHA-256 of its tarball.
- the version and the flags of every package, and which packages the
  compiler provides.
- the components of each package of the project. These are the outputs of
  `buildCabalProject`.

Cabal files record no hashes, so the lockfile holds what the build needs
from them. `cabal.project.freeze` pins versions and the index state, and
the lockfile adds the hashes and the revisions. The lockfile holds a
format `version` and a `hash` of its own content. It records the index
state it planned with (`indexState`), which the next `lock` plans with
again. An `index-state` in the files of the project takes precedence, and
the lockfile then records none.

The command then checks the lock: it fetches the locked sources through
Nix and plans the project again from those alone, and the plan must match
the lock.

## Working offline

```zsh
eval "$(nix run github:nix-purifiers/cabal-purifier -- prefetch)"
```

`prefetch` realizes in the Nix store everything the lockfile lists for
the current system that day-to-day development needs:

- the locked sources, which fill the no-index repository that the shim
  builds from;
- the toolchain, which is the GHC of the plan in the lock, cabal-install, and the
  haskell-language-server for that GHC.

It keeps them alive with a garbage-collector root,
`cabal-purifier.lock.prefetch`, beside the lockfile, writes the shim to
`dist-newstyle/cabal-purifier/bin/cabal`, and prints a `PATH` export that
puts the shim and the toolchain first. After a prefetch, `cabal build`,
`cabal run`, `cabal test` and the editor work with the network cut off.

The shim runs cabal with a Cabal directory whose only repository is the
locked one, and with an offline copy of the configuration of the project. The
Cabal directory belongs to the command, so your `~/.config/cabal/config`
does not apply, and the package store is under
`dist-newstyle/cabal-purifier/cabal`.

### How the build resolves offline

The Nix builder makes a Cabal no-index repository (`file+noindex://`) of
the locked sources. It holds each package tarball, each Hackage revision
of a package description as `<name>-<version>.cabal` beside its tarball,
and each package from a source repository as a tarball packed from its
locked checkout. The build runs cabal with that repository as its only
repository, and with an offline copy of the configuration of the project
(`nix/lib/offline_project.py`). The copy leaves out the
`source-repository-package` and `repository` sections and the
`index-state`, replaces each package URL with its unpacked directory, and
adds the constraints of the lock, so Cabal resolves to the locked plan.
After the build, the builder compares the plan that Cabal made with the
lock and fails on
any difference.

## Editor

`prefetch` puts the `haskell-language-server` of the toolchain and the `cabal`
shim first on `PATH`. An editor started from that shell, or with that
`PATH`, loads the project through the shim, so the build tool calls of the
language server go to the locked sources and nothing is downloaded.
A `.envrc` with the `eval` line from [Working offline](#working-offline) does
the same for direnv.

## Troubleshooting

The Nix library checks the lockfile whenever it reads it (`readLock`
returns the problems, and the builder fails evaluation with them), and
the command makes the same checks. Each problem names the command that
fixes it, which is `cabal-purifier lock` for every one of these:

| Problem | What the message says |
| --- | --- |
| A project file changed since the lock | `hello.cabal changed since the lock`, and the shim exits with an error. |
| The lockfile is not valid JSON | `is not valid JSON` with the position. |
| A section is missing, or the format `version` differs from the one this command writes | `is damaged: it has no <sections>`, or the version the file has and the version this command writes. |
| The lockfile changed after `lock` wrote it | `its content does not match its hash`. |
| A repository file or package URL names a download the lock lacks, or a plan uses a package no locked source provides | `names no download <path>` or `uses <package>, which no locked source provides`. |
| A download no longer matches its hash | Nix reports the mismatch, and the command says the lockfile was edited or the source changed upstream. |
| A build whose plan differs from the lock | The build lists the packages that differ. |
| A dependency newer than the recorded index state | Cabal cannot plan it, and the command says to run `cabal-purifier update`. |

## Supported language repositories

Every kind of source that cabal-install fetches works:

- **Hackage and other package repositories**, with Hackage revisions of
  package descriptions. A repository that needs credentials takes them
  through `fetchers.fetchurl`.
- **Git source repositories** (`source-repository-package` with
  `type: git`), with their submodules, which Cabal checks out too. The Nix
  sandbox has no SSH keys, so a repository over SSH is locked at the HTTPS
  URL of the same host and path. A private repository takes a credentialed
  fetcher through `fetchers.fetchgit`. The lock run itself uses your SSH
  keys and git credentials.
- **Mercurial and Darcs source repositories.** A Mercurial source needs a
  `tag`. A Darcs source without a `tag` is locked by the Darcs context of
  the checkout Cabal made in the lock run.
- **Package URLs** in `packages:`.
- **Local packages inside the project**, which are the outputs of the project,
  and **local tarballs and no-index repositories inside the project**.
- **Local packages outside the project**, such as `packages: ../shared`.
  The lock lists them as `externalPaths`, and the build takes each tree as
  an argument, keyed by the path the lock gives it:

  ```nix
  pkgs.buildCabalProject {
    src = ./.;
    externalPaths."../shared" = inputs.shared;
  }
  ```

The command refuses these:

- **Subversion, Bazaar, CVS and Pijul source repositories.** cabal-install
  does not sync them (`cabal update` fails with "sync repo not yet
  supported", or with `SourceRepoRepoTypeUnsupported` for Pijul), so a
  project cannot use them and there is nothing to lock.
- **Local packages given by absolute path.** A Nix build can create files
  only inside its own build directory, so it cannot put a tree at an
  absolute path. Paths relative to the project work.
- **Imports by URL in `cabal.project`.** Cabal fetches such an import while
  it reads the project, before any build step, so the offline copy cannot
  hold it, and the command explains this. Imports of local files work.

A `.cabal` file names system libraries (`extra-libraries`,
`pkgconfig-depends`) but not where they come from, so the builder takes
them as `nativeBuildInputs` and `buildInputs`.

## Examples

### ShellCheck

[ShellCheck](https://github.com/koalaman/shellcheck) is a single Haskell
package with a library, an executable and a test suite, and no
`cabal.project`. To build it with Nix, lock it in a checkout of the
release:

```zsh
git clone --branch v0.11.0 https://github.com/koalaman/shellcheck
cd shellcheck
nix run github:nix-purifiers/cabal-purifier -- lock --lockfile ../shellcheck.lock.json
```

The lockfile goes outside the checkout, because the author of ShellCheck
does not keep one. A flake then builds the release from the lockfile:

```nix
{
  inputs.cabal-purifier.url = "github:nix-purifiers/cabal-purifier";
  inputs.nixpkgs.follows = "cabal-purifier/nixpkgs";
  inputs.shellcheck = {
    url = "github:koalaman/shellcheck/v0.11.0";
    flake = false;
  };

  outputs = { nixpkgs, cabal-purifier, shellcheck, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ cabal-purifier.overlays.default ];
      };
      project = pkgs.buildCabalProject {
        src = shellcheck;
        lockFile = ./shellcheck.lock.json;
      };
    in
    {
      packages.${system}.default = project.packages.ShellCheck.executables.shellcheck;
      checks.${system}.tests = project.tests;
    };
}
```

`nix build` builds `shellcheck` in the sandbox, and `nix flake check` runs
the test suite of ShellCheck. To work on ShellCheck itself, run this in
the checkout, and then use `cabal build` and `cabal test` as usual:

```zsh
eval "$(nix run github:nix-purifiers/cabal-purifier -- prefetch --lockfile ../shellcheck.lock.json)"
```

## Credits

cabal-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): a lock run
with empty caches that records every download, a builder that runs the
tool itself in the sandbox from that lockfile, an offline interactive mode
on the same locked files, and publishing what Nix built. The
[cargo (libnix)](https://github.com/nixcloud/cargo) project by nixcloud
inspired the nix-purifiers family.

## License

MIT
