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
  # The backend's return route lives in its own table, selected by source.
  routeTable = 51820;

  isGateway = cfg.role == "gateway";
  peerName = if isGateway then backendName else gatewayName;
  peerPublicKey = lib.trim (
    builtins.readFile "${config.clan.core.settings.directory}/vars/per-machine/${peerName}/ipv4-forward-wg/publicKey/value"
  );
in
{
  options.hyper.ipv4Forward.role = lib.mkOption {
    type = lib.types.enum [
      "gateway"
      "backend"
    ];
    description = "gateway (${gatewayName}) owns the public IPv4 and forwards it; backend (${backendName}) serves it.";
  };

  config = lib.mkMerge [
    {
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
        ];
      };
    })
  ];
}
