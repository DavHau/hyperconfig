# Lend sgp's public IPv4 to som. som has only IPv6 publicly (IPv4 is behind
# the AIS NAT) and sgp's IPv6 is not routed, so the link is a WireGuard
# tunnel over IPv4 that som dials out to sgp, kept open through the NAT by
# keepalives.
#
# gateway (sgp): every new inbound IPv4 connection to its public address is
#   DNATed through the tunnel to som, including 22/tcp (hermes dashboards
#   reach som over SSH). sgp's own SSH on the public address moves to
#   `gatewaySshPort`; 22 still works over the meshes. Only that port and the
#   tunnel stay on sgp. Replies to sgp's own outbound connections are
#   conntrack-matched and never reach the DNAT chain, so sgp's meshes and
#   updates keep working.
# backend (som): receives those connections with the client's source address
#   intact. Only traffic sourced from the tunnel address is policy-routed back
#   through the tunnel; som's own traffic keeps using the home uplink. som's
#   firewall still decides which ports are reachable.
#   Connections som forwards on (DNAT to a container slot,
#   hyperhermes' container-slots) answer from the container's own address, which
#   the source rule does not match, and their un-DNAT back to the tunnel
#   address happens only after routing. So a connection that arrives through
#   the tunnel is marked (ct mark), its packets from elsewhere carry the mark
#   as fwmark, and a mark rule sends them to the tunnel's table too. The
#   container's MSS (from a 1500 veth) is clamped to the tunnel on the way
#   out, as the gateway does for its side.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.ipv4Forward;

  gatewayName = "sgp";
  backendName = "som";
  publicIPv4 = "38.89.142.76";
  port = 51820;
  gatewaySshPort = 21;
  gatewayAddress = "10.99.0.1";
  backendAddress = "10.99.0.2";
  interface = "wg-v4fwd";
  # The backend's return route lives in its own table, selected by source
  # (or by returnMark, for connections it forwards on).
  routeTable = 51820;
  # 0x10000000, decimal (networkd and nft both read that). A bit no other
  # fwmark user on som sets or masks: tailscale's 0xff0000 mask, the Mullvad
  # app's 0x6d6f6c65 (services.mullvad-vpn, ./vpn.nix; matched with a mask
  # by the priority-101 rule below, any shared bit would send the app's
  # tunnel packets into wg-v4fwd) and the container slots' egress mark
  # (hyperhermes' container-slots, which asserts that side: machines/som
  # lists this mark in its foreignMarks). The others are asserted below.
  returnMarkInt = 268435456;
  returnMark = toString returnMarkInt;
  foreignMarks = {
    mullvad-app = 1836018789;
    tailscale = 16711680;
  };

  isGateway = cfg.role == "gateway";
  peerName = if isGateway then backendName else gatewayName;
  peerPublicKey = lib.trim (
    builtins.readFile "${config.clan.core.settings.directory}/vars/per-machine/${peerName}/ipv4-forward-wg/publicKey/value"
  );
in
{
  options.hyper.ipv4Forward = {
    role = lib.mkOption {
      type = lib.types.enum [
        "gateway"
        "backend"
      ];
      description = "gateway (${gatewayName}) owns the public IPv4 and forwards it; backend (${backendName}) serves it.";
    };
    returnMark = lib.mkOption {
      type = lib.types.int;
      readOnly = true;
      default = returnMarkInt;
      description = "fwmark bit the backend gives forwarded connections' return traffic (other mark users check against it).";
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList (owner: mark: {
        assertion = builtins.bitAnd returnMarkInt mark == 0;
        message = "hyper.ipv4Forward: returnMark overlaps ${owner}'s fwmark";
      }) foreignMarks;

      clan.core.vars.generators.ipv4-forward-wg = {
        files.privateKey.owner = "systemd-network";
        files.publicKey.secret = false;
        runtimeInputs = [ pkgs.wireguard-tools ];
        script = ''
          wg genkey > "$out/privateKey"
          wg pubkey < "$out/privateKey" > "$out/publicKey"
        '';
      };

      systemd.network.netdevs."50-${interface}" = {
        netdevConfig = {
          Name = interface;
          Kind = "wireguard";
        };
        wireguardConfig.PrivateKeyFile =
          config.clan.core.vars.generators.ipv4-forward-wg.files.privateKey.path;
      };
    }

    (lib.mkIf isGateway {
      systemd.network.netdevs."50-${interface}" = {
        wireguardConfig.ListenPort = port;
        wireguardPeers = [
          {
            PublicKey = peerPublicKey;
            AllowedIPs = [ "${backendAddress}/32" ];
          }
        ];
      };
      systemd.network.networks."50-${interface}" = {
        matchConfig.Name = interface;
        address = [ "${gatewayAddress}/30" ];
      };

      networking.firewall.allowedUDPPorts = [ port ];
      # openssh.openFirewall opens both ports.
      services.openssh.ports = [
        22
        gatewaySshPort
      ];
      boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;

      networking.nftables.enable = true;
      networking.nftables.tables.ipv4-forward = {
        family = "ip";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;
            iifname "${interface}" return
            ip daddr != ${publicIPv4} return
            tcp dport ${toString gatewaySshPort} return
            udp dport ${toString port} return
            dnat to ${backendAddress}
          }

          # The tunnel MTU (1420) is below the uplink's; clamp forwarded
          # handshakes so clients never send segments that do not fit.
          chain forward {
            type filter hook forward priority mangle; policy accept;
            oifname "${interface}" tcp flags syn tcp option maxseg size set rt mtu
            iifname "${interface}" tcp flags syn tcp option maxseg size set rt mtu
          }
        '';
      };
    })

    (lib.mkIf (!isGateway) {
      systemd.network.netdevs."50-${interface}".wireguardPeers = [
        {
          PublicKey = peerPublicKey;
          Endpoint = "${publicIPv4}:${toString port}";
          # Replies go to arbitrary client addresses.
          AllowedIPs = [ "0.0.0.0/0" ];
          RouteTable = routeTable;
          PersistentKeepalive = 25;
        }
      ];
      systemd.network.networks."50-${interface}" = {
        matchConfig.Name = interface;
        address = [ "${backendAddress}/30" ];
        routingPolicyRules = [
          {
            From = backendAddress;
            Table = routeTable;
            Priority = 100;
          }
          {
            FirewallMark = "${returnMark}/${returnMark}";
            Table = routeTable;
            Priority = 101;
          }
        ];
      };

      networking.nftables.enable = true;
      networking.nftables.tables.ipv4-forward = {
        family = "ip";
        content = ''
          chain prerouting {
            type filter hook prerouting priority mangle; policy accept;
            iifname "${interface}" ct state new ct mark set ct mark or ${returnMark}
            iifname != "${interface}" ct mark and ${returnMark} == ${returnMark} meta mark set meta mark or ${returnMark}
          }

          chain forward {
            type filter hook forward priority mangle; policy accept;
            oifname "${interface}" tcp flags syn tcp option maxseg size set rt mtu
          }
        '';
      };
    })
  ];
}
