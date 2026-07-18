# VibePN p2p mesh VPN - packages only, configured manually for now.
# CLI: `vpn identity init`, `vpn network create/join ...`
# Daemon: `vpnd --config /etc/vibepn/vpnd.toml`
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.vibepn.packages.${pkgs.stdenv.hostPlatform.system}.vibepn
    inputs.vibepn.packages.${pkgs.stdenv.hostPlatform.system}.vpnd
  ];
}
