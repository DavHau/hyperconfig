# SimpleX Chat terminal client (CLI daemon).
#
# Nixpkgs only carries simplex-chat-desktop (GUI); the CLI that exposes the
# WebSocket bot API (`simplex-chat -p <port>`) is not packaged. Building
# from source means haskell.nix cross-bootstrapping GHC (hours, no public
# cache), so we patchelf the upstream Ubuntu 24.04 release binary instead —
# pinned by version + sha256 from the GitHub release.
#
# Factored out of simplex-chat.nix so the service module and ad-hoc
# `nix build` smoke tests use the exact same derivation.
{ pkgs }:

pkgs.stdenv.mkDerivation rec {
  pname = "simplex-chat";
  version = "6.5.6";

  src = pkgs.fetchurl {
    url = "https://github.com/simplex-chat/simplex-chat/releases/download/v${version}/simplex-chat-ubuntu-24_04-x86_64";
    hash = "sha256-CuwKHr017D37uflp9dWOQmnI7KI29b4JZ4C5Rl3aLb4=";
  };

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];

  buildInputs = [
    pkgs.stdenv.cc.cc.lib # libgcc_s/libstdc++
    pkgs.gmp
    pkgs.zlib
    pkgs.openssl
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/simplex-chat
    runHook postInstall
  '';

  meta = {
    description = "SimpleX Chat terminal client with WebSocket bot API";
    homepage = "https://github.com/simplex-chat/simplex-chat";
    license = pkgs.lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
  };
}
