# Wakaru 1.14.0 (github.com/pionxzh/wakaru, Apache-2.0), the JavaScript
# unbundler behind REA's recover_javascript_sources (REA_WAKARU_COMMAND):
# REA accepts `wakaru ^1.13.0` and verified 1.14.0's official Linux
# binary, which this is, patched for the Nix loader (REA records the
# binary's digest as provenance only). Not in nixpkgs.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "wakaru";
  version = "1.14.0";

  src = fetchurl {
    url = "https://github.com/pionxzh/wakaru/releases/download/v${finalAttrs.version}/wakaru-linux-x64.tar.gz";
    hash = "sha256-2w5iADRyMZWrQm6U0A1V29j9AQapKK2iVj8RAxltCfo=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 wakaru $out/bin/wakaru
    runHook postInstall
  '';

  meta = {
    description = "JavaScript decompiler and unbundler";
    homepage = "https://github.com/pionxzh/wakaru";
    license = lib.licenses.asl20;
    mainProgram = "wakaru";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
