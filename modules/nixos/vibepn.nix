# VibePN p2p mesh VPN - packages only, configured manually for now.
# CLI: `vpn identity init`, `vpn network create/join ...`
# Daemon: `vpnd --config /etc/vibepn/vpnd.toml`
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.vibepn.packages.${pkgs.stdenv.hostPlatform.system}.vibepn
    inputs.vibepn.packages.${pkgs.stdenv.hostPlatform.system}.vpnd
  ];

  # The upstream VM tests run firewall-free; on real machines the default
  # NixOS firewall breaks discovery. Open:
  #   5353/udp  mDNS local peer discovery
  #   4001      libp2p control plane (tcp + quic) - descriptor rendezvous, hole punching
  #   51820/udp data plane ([[network]] listen)
  networking.firewall.allowedTCPPorts = [ 4001 ];
  networking.firewall.allowedUDPPorts = [ 5353 4001 51820 ];
}
