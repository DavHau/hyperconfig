# VibePN p2p mesh VPN - upstream NixOS module (services.vibepn) runs vpnd
# and joins the network declaratively. Open networks are a pure function of
# the invite phrase (deterministic network key), so the shared generator
# below mints the whole network: no imperative `vpn network create`, no
# prompt. All members are born resolved from the same phrase.
{ config, inputs, pkgs, ... }:
{
  imports = [ inputs.vibepn.nixosModules.default ];

  clan.core.vars.generators.vibepn = {
    share = true;
    files.invite.secret = true;
    runtimeInputs = [
      inputs.vibepn.packages.${pkgs.stdenv.hostPlatform.system}.vibepn
      pkgs.gnused
    ];
    # Throwaway state dir: only the phrase matters; the identity minted for
    # `network create` is discarded (every node derives its own at boot).
    script = ''
      state=$(mktemp -d)
      vpn --state-dir "$state" identity init > /dev/null
      vpn --state-dir "$state" network create hyper \
        | sed -n 's/^invite: //p' | tr -d '\n' > "$out"/invite
    '';
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
