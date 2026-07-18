# VibePN p2p mesh VPN - upstream NixOS module (services.vibepn) runs vpnd
# and joins the network declaratively. Creation stays imperative: run
# `vpn network create hyper` once, then store the invite phrase in the
# shared clan var below (`clan vars generate --generator vibepn`).
{ config, inputs, ... }:
{
  imports = [ inputs.vibepn.nixosModules.default ];

  clan.core.vars.generators.vibepn = {
    share = true;
    prompts.invite.type = "hidden";
    prompts.invite.persist = true;
  };

  services.vibepn = {
    enable = true;
    # Opens only the declared data ports below. The libp2p control plane
    # (4001) stays closed: discovery/hole punching work outbound-only.
    openFirewall = true;
    networks.hyper = {
      inviteFile = config.clan.core.vars.generators.vibepn.files.invite.path;
      listenPort = 51820;
      # bam and edi already serve nginx on 443; keep the quic/tls rungs off
      # the default 443 so every member can bind them.
      quicPort = 51821;
      tlsPort = 51821;
    };
  };
}
