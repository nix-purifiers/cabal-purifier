# SPDX-License-Identifier: MIT
#
# The locked sources of a project, as one store path:
#
#   repo/            a Cabal no-index repository (`file+noindex://`). It
#                    holds each package tarball as <name>-<version>.tar.gz,
#                    and each Hackage revision of a package description as
#                    <name>-<version>.cabal beside its tarball, where Cabal
#                    reads it in place of the description in the tarball.
#                    A package from a `source-repository-package` is a
#                    tarball packed from its locked checkout.
#   remote/<n>/      the unpacked tarball of the n-th package URL in the
#                    project's `packages` field
#   remote.json      the directory of each of those URLs, for
#                    offline_project.py
#
# Cabal writes its `noindex.cache` into the repository directory, so a
# build reads it through a writable directory of links to repo/.
{
  lib,
  runCommand,
  fetchgit,
  fetchhg,
  fetchdarcs,
  fetchpijul,
  gnutar,
  gzip,
  lockFile,
  # The project root, for repository files that the project itself holds.
  src ? null,
  # Replaces the built-in fetcher for files; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix {
    inherit
      lock
      fetchgit
      fetchhg
      fetchdarcs
      fetchpijul
      fetchurl
      ;
  };

  linked = lib.filter (f: f ? from) lock.repository;
  packed = lib.filter (f: f ? pack) lock.repository;
  fromProject = lib.filter (f: f ? project) lock.repository;

  projectFile =
    f:
    if src == null then
      throw "cabal-purifier: the repository file ${f.file} comes from the project; pass `src`."
    else
      "${src}/${f.project}";

  remoteDirs = lib.imap0 (i: r: {
    inherit (r) uri;
    tarball = fetch (lock.download r.from);
    dir = "remote/${toString i}";
  }) lock.remotePackages;
in
# The manifests go to the builder as files, since a large project locks
# hundreds of packages and the list would not fit in an environment
# variable.
runCommand "cabal-purifier-repository"
  {
    nativeBuildInputs = [
      gnutar
      gzip
    ];
    links = lib.concatMapStrings (f: "${f.file}\t${fetch (lock.download f.from)}\n") linked;
    projectLinks = lib.concatMapStrings (f: "${f.file}\t${projectFile f}\n") fromProject;
    packs = lib.concatMapStrings (
      f: "${f.file}\t${fetch (lock.download f.pack.from)}\t${f.pack.subdir}\t${f.pack.root}\n"
    ) packed;
    remotes = lib.concatMapStrings (r: "${r.dir}\t${r.tarball}\n") remoteDirs;
    remoteJson = builtins.toJSON (
      builtins.listToAttrs (
        map (r: {
          name = r.uri;
          value = r.dir;
        }) remoteDirs
      )
    );
    passAsFile = [
      "links"
      "projectLinks"
      "packs"
      "remotes"
      "remoteJson"
    ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit lock; };
  }
  ''
    mkdir -p $out/repo $out/remote
    while IFS=$'\t' read -r file target; do
      ln -s "$target" "$out/repo/$file"
    done < "$linksPath"
    while IFS=$'\t' read -r file target; do
      ln -s "$target" "$out/repo/$file"
    done < "$projectLinksPath"
    # A package from a source repository: the package's directory of the
    # checkout, packed the way `cabal sdist` lays a tarball out, with its
    # files below <name>-<version>/. The tarball is reproducible: sorted
    # entries, fixed times and owners, and gzip without a name or time.
    while IFS=$'\t' read -r file checkout subdir root; do
      staging="$TMPDIR/pack/$root"
      mkdir -p "$(dirname "$staging")"
      cp -r --no-preserve=mode "$checkout/$subdir" "$staging"
      tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
        -C "$TMPDIR/pack" -c "$root" | gzip -9n > "$out/repo/$file"
      rm -rf "$TMPDIR/pack"
    done < "$packsPath"
    # A package URL: its tarball unpacked, with the tarball's single top
    # directory as the package directory.
    while IFS=$'\t' read -r dir tarball; do
      mkdir -p "$TMPDIR/unpack"
      tar -xzf "$tarball" -C "$TMPDIR/unpack"
      top=$(ls -A "$TMPDIR/unpack")
      if [ "$(echo "$top" | wc -l)" = 1 ] && [ -d "$TMPDIR/unpack/$top" ]; then
        mv "$TMPDIR/unpack/$top" "$out/$dir"
      else
        mv "$TMPDIR/unpack" "$out/$dir"
      fi
      rm -rf "$TMPDIR/unpack"
    done < "$remotesPath"
    sed "s|\"remote/|\"$out/remote/|g" "$remoteJsonPath" > $out/remote.json
  ''
