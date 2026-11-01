# SPDX-License-Identifier: MIT
{
  inputs.caisson.url = "github:nix-caisson/caisson";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  # Same channel as the main flake, so dev-partition evals agree with the
  # exported pkgSet.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  # A real-world project for the checks: ShellCheck v0.11.0, which
  # tests/real-world/shellcheck holds the lockfile of.
  inputs.shellcheck.url = "github:koalaman/shellcheck/aac0823e6b58f8a499e856e93738082691cbf212";
  inputs.shellcheck.flake = false;
  outputs = { ... }: { };
}
