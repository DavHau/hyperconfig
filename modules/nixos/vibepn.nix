# Per-machine VibePN settings for the `vibe` network. Membership, the
# upstream module import, and the shared invite phrase come from the clan
# service instance (inventory instances.vibe, modules/flake-parts/
# nixosConfigurations.nix) - this file only tunes the plain NixOS options.
{
  services.vibepn = {
    # Opens only the declared data ports below. The libp2p control plane
    # (4001) stays closed: discovery/hole punching work outbound-only.
    openFirewall = true;
    networks.vibe = {
      listenPort = 51820;
      # bam and edi already serve nginx on 443, and 51821 is taken by the
      # legacy wg-edi kernel WireGuard listener on edi (bit us once: kernel
      # sockets show no owner in `ss -ulpn`, so the QUIC rung silently
      # failed to bind). 51822 is clear of both nginx and the 5182x
      # WireGuard neighborhood's existing tenants. Upstream default-port
      # rethink tracked in VibePN backlog/default-ports.md.
      quicPort = 51822;
      tlsPort = 51822;
    };
  };
}
