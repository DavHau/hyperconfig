# Mercurygram's aesgcm-proxy: folds the Encryption/Crypto-Key headers of
# Telegram's legacy WebPush (aesgcm, draft 4) into the body, so a
# UnifiedPush distributor (our ntfy) can carry it to the phone, where
# Mercurygram decrypts it. Upstream: https://github.com/Mercurygram/aesgcm-proxy
# (MIT OR Apache-2.0). Module: modules/nixos/telegram-push-gateway.nix.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  openssl,
}:
rustPlatform.buildRustPackage {
  pname = "aesgcm-proxy";
  version = "0.1.0-unstable-2026-10-28";

  src = fetchFromGitHub {
    owner = "Mercurygram";
    repo = "aesgcm-proxy";
    rev = "3ba3cbc12812822a67771d8ddaf5e20c654b5753";
    hash = "sha256-mXNeI5Kr/mKnB82eItvUOz6sHMxCYzRcfESJXatOdNI=";
  };

  cargoHash = "sha256-2QHUG/Rvp8hrnwEQ10qOEAEjoBVBp53jpfcxnUkuQHs=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = {
    description = "Legacy WebPush (aesgcm) to UnifiedPush rewrite proxy for Mercurygram";
    homepage = "https://github.com/Mercurygram/aesgcm-proxy";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "aesgcm-proxy";
  };
}
