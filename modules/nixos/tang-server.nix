# Tang server: lets LAN peers unlock their encrypted root at boot without a
# passphrase (client side: ./zfs-remote-unlock, hyper.zfsRemoteUnlock.tang).
#
# Tang holds one key pair and answers blinded requests; it learns nothing
# about the clients and stores nothing per client. Its keys are clan vars,
# so they rest on this machine's encrypted root: a stolen, powered-off
# server cannot help a stolen client. Only machines with an encrypted root
# may run this.
#
# Reachable on link-local only, at a fixed address on the LAN interface:
# independent of DHCP leases and unroutable by construction, so neither the
# internet nor an overlay network (zerotier, wireguard, ...) can reach it.
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.tangServer;
  port = 7654;
  keys = config.clan.core.vars.generators.tang.files;
in
{
  options.hyper.tangServer = {
    enable = lib.mkEnableOption "a Tang server for LAN peers' boot unlock";
    interface = lib.mkOption {
      type = lib.types.str;
      example = "br0";
      description = "LAN interface that carries `address` and accepts Tang requests.";
    };
    address = lib.mkOption {
      type = lib.types.strMatching "fe80::[0-9a-f:]+";
      example = "fe80::7a6e:1";
      description = "Fixed link-local address clients bind to. Unique per server.";
    };
    networkdUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "40-br0";
      description = ''
        systemd-networkd network that owns `interface`; the address is added
        there. null: the interface is NetworkManager's and a dispatcher hook
        adds the address on every activation.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    clan.core.vars.generators.tang = {
      files."sig.jwk" = { };
      files."exc.jwk" = { };
      # Signed public keys, what /adv serves. Clients encrypt against it
      # offline, so binding needs neither this machine nor the network.
      files."adv.jws".secret = false;
      runtimeInputs = [
        pkgs.jose
        pkgs.tang
        pkgs.gnused
      ];
      # Same keys tangd-keygen makes; the advertisement is tangd's own /adv
      # reply with the HTTP head cut off.
      script = ''
        jose jwk gen -i '{"alg":"ES512"}' -o "$out/sig.jwk"
        jose jwk gen -i '{"alg":"ECMR"}' -o "$out/exc.jwk"
        printf 'GET /adv HTTP/1.1\r\n\r\n' | ${pkgs.tang}/libexec/tangd "$out" |
          sed '1,/^\r$/d' > "$out/adv.jws"
      '';
    };

    services.tang = {
      enable = true;
      listenStream = [ (toString port) ];
      ipAddressAllow = [ "fe80::/10" ];
    };
    # Serve the clan-var keys instead of a self-generated state directory.
    # tangd loads every *.jwk in the directory it is given.
    systemd.services."tangd@".serviceConfig = {
      LoadCredential = [
        "sig.jwk:${keys."sig.jwk".path}"
        "exc.jwk:${keys."exc.jwk".path}"
      ];
      ExecStart = lib.mkForce "${config.services.tang.package}/libexec/tangd %d";
    };

    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [ port ];

    systemd.network.networks = lib.mkIf (cfg.networkdUnit != null) {
      ${cfg.networkdUnit}.address = [ "${cfg.address}/64" ];
    };
    # NetworkManager flushes the device's addresses when it goes down, so
    # re-add on every activation.
    networking.networkmanager.dispatcherScripts = lib.mkIf (cfg.networkdUnit == null) [
      {
        source = pkgs.writeShellScript "tang-link-local" ''
          if [ "$1" = ${lib.escapeShellArg cfg.interface} ] && [ "$2" = up ]; then
            ${pkgs.iproute2}/bin/ip -6 addr replace ${cfg.address}/64 dev "$1"
          fi
        '';
      }
    ];
  };
}
