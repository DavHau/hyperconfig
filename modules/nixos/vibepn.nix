# VibePN p2p mesh VPN - packages only, configured manually for now.
# CLI: `vpn identity init`, `vpn network create/join ...`
# Daemon: `vpnd --config /etc/vibepn/vpnd.toml`
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.vibepn.packages.${pkgs.stdenv.hostPlatform.system}.vibepn
    inputs.vibepn.packages.${pkgs.stdenv.hostPlatform.system}.vpnd
  ];

  # The host firewall blocked VibePN's post-discovery dials (verified: 4001 was
  # closed on amy/bam pre-integration; 5353 was already open via the shared
  # module stack, so mDNS discovery itself worked). Open:
  #   4001      libp2p control plane (tcp + quic) - descriptor rendezvous, hole punching
  #   51820/udp data plane ([[network]] listen)
  # Remove once VibePN handles firewalled hosts (VibePN backlog/lan-firewalled-hosts.md).
  networking.firewall.allowedTCPPorts = [ 4001 ];
  networking.firewall.allowedUDPPorts = [ 4001 51820 ];
}
