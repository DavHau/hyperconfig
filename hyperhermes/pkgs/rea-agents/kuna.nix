# Kuna (github.com/Noelo-Lab/kuna, Apache-2.0), a static decompiler REA
# can use as its analysis provider instead of Ghidra (REA_KUNA_COMMAND;
# `open_binary` with provider_id "kuna"). Pinned to 1.833, the release
# REA verified (others run but are reported unverified); the official
# static musl build, so nothing to patch. Not in nixpkgs.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "kuna";
  version = "1.833";

  src = fetchurl {
    url = "https://github.com/Noelo-Lab/kuna/releases/download/v${finalAttrs.version}/kuna-v${finalAttrs.version}-linux-x86_64-musl.tar.gz";
    hash = "sha256-OzrHWRk2bz/mPL70r141c2HIZRYXZdlQwDjiOXxBcp8=";
  };

  installPhase = ''
    runHook preInstall
    install -Dm755 kuna $out/bin/kuna
    runHook postInstall
  '';

  dontStrip = true;

  meta = {
    description = "Static decompiler";
    homepage = "https://github.com/Noelo-Lab/kuna";
    license = lib.licenses.asl20;
    mainProgram = "kuna";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
