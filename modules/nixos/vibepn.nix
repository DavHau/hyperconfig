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
      # bam and edi already serve nginx on 443; keep the quic/tls rungs off
      # the default 443 so every member can bind them.
      quicPort = 51821;
      tlsPort = 51821;
    };
  };
}
