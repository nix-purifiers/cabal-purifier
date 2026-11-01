# SPDX-License-Identifier: MIT
#
# The fetcher for locked downloads. The lock holds these kinds of download,
# the shapes of the shared nix-purifiers library:
#
#   { path, url, mirrors, hash }
#     a file, where hash is the SRI hash of the file and mirrors are other
#     URLs that serve the same bytes
#   { path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash }
#     a git checkout, where hash is the SRI hash that nix-prefetch-git
#     reports for it; Cabal's checkouts have no `.git`, so leaveDotGit is
#     false and commitObject is null
#   { path, hg = { url, rev }, hash }
#     a Mercurial checkout, as nixpkgs' fetchhg produces it
#   { path, darcs = { url, rev, context }, hash }
#     a Darcs checkout at the tag `rev` or at the state the Darcs context
#     text `context` names (exactly one of the two is not null), as
#     nixpkgs' fetchdarcs produces it
#
# By default a file is a fixed-output derivation on Nix's built-in fetcher
# (the same derivation <nix/fetchurl.nix> makes). A fixed-output store
# path depends only on its name and hash, so the default fetcher and
# nixpkgs' fetchurl produce the same paths.
#
# `fetchurl`, when given, replaces the built-in fetcher for files. It is
# called with { name, urls, hash } and is the place for credentials
# (nixpkgs' fetchurl takes `netrcPhase`).
{
  lock,
  fetchgit,
  fetchhg,
  fetchdarcs,
  fetchurl ? null,
}:
download:
let
  name = lock.downloadName download;
in
if download ? git then
  fetchgit {
    inherit name;
    inherit (download.git) url rev leaveDotGit;
    fetchSubmodules = download.git.submodules;
    inherit (download) hash;
  }
else if download ? hg then
  fetchhg {
    inherit name;
    inherit (download.hg) url rev;
    inherit (download) hash;
  }
else if download ? darcs then
  fetchdarcs (
    {
      inherit name;
      inherit (download.darcs) url;
      inherit (download) hash;
    }
    // (
      if download.darcs.rev != null then
        { inherit (download.darcs) rev; }
      else
        { context = builtins.toFile "darcs-context" download.darcs.context; }
    )
  )
else if fetchurl != null then
  fetchurl {
    inherit name;
    urls = [ download.url ] ++ download.mirrors;
    inherit (download) hash;
  }
else
  derivation {
    inherit name;
    builder = "builtin:fetchurl";
    system = "builtin";
    inherit (download) url;
    urls = [ download.url ] ++ download.mirrors;
    outputHash = download.hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
