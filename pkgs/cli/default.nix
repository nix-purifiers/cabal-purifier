# SPDX-License-Identifier: MIT
#
# The cabal-purifier command: bin/cabal-purifier on nixpkgs' Python, with
# the Nix library it realizes lockfiles with, the source of the shared
# library that fetches the downloads, and the nixpkgs that
# `cabal-purifier publish` builds with. The user's PATH comes first, so the
# lock run plans with the user's GHC and cabal when there are any, and with
# nixpkgs' otherwise.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  cabal-install,
  ghc,
  curl,
  gitMinimal,
  nix-prefetch-git,
  path,
  version,
  # The source of github:nix-purifiers/purifier, which the cabal-purifier
  # package overlay passes.
  purifierSource ? throw "cabal-purifier: the cli package needs `purifierSource`, which the cabal-purifier package overlay passes",
}:
stdenvNoCC.mkDerivation {
  pname = "cabal-purifier";
  inherit version;
  src = ../../bin;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm644 cabal-purifier "$out/libexec/cabal-purifier.py"
    # cabal downloads over HTTPS through curl. git serves cabal's source
    # repositories, and nix-prefetch-git hashes them for the lock.
    makeWrapper ${python3}/bin/python3 "$out/bin/cabal-purifier" \
      --add-flags "$out/libexec/cabal-purifier.py" \
      --set CABAL_PURIFIER_LIB ${../../nix/lib} \
      --set CABAL_PURIFIER_NIXPKGS ${path} \
      --set CABAL_PURIFIER_PURIFIER ${purifierSource} \
      --set CABAL_PURIFIER_SELF "$out/bin/cabal-purifier" \
      --suffix PATH : ${
        lib.makeBinPath [
          cabal-install
          ghc
          curl
          gitMinimal
          nix-prefetch-git
        ]
      }
    makeWrapper "$out/bin/cabal-purifier" "$out/bin/cabal" \
      --set CABAL_PURIFIER_SHIM 1
    runHook postInstall
  '';
  meta = {
    description = "Locks what a Cabal project downloads, so that Nix can build it offline";
    license = lib.licenses.mit;
    mainProgram = "cabal-purifier";
  };
}
