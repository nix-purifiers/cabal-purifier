# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The cabal-purifier command.
  cli = callPackage ./cli {
    version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
  };
}
