# Selected users reach the internet only through a Mullvad WireGuard tunnel;
# the rest of the host keeps its normal route. Clan wiring and the pinned
# Singapore relays are in ./default.nix; ./test.nix exercises this file.
#
# Routing, after tailscale's rules (5210-5270) so its tailnet stays direct:
#   5999  to <directPrefixes>  lookup main    every user; others use main anyway
#   6000  uid X  lookup main suppress_prefixlength 0
#                              LAN, meshes, ygg: any route but a default
#   6001  uid X  lookup 51830  default dev wg-mullvad, v4 and v6
# networkd removes these rules with the tunnel's link, and the listed users
# then fall through to the main table. The nftables output chain below is
# the kill switch: a listed user's packet to a public address leaves through
# wg-mullvad or is refused.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.mullvadEgress;
  iface = "wg-mullvad";
  table = 51830;

  uids = map (name: config.users.users.${name}.uid) cfg.users;
  ipv4Prefixes = lib.filter (p: !lib.hasInfix ":" p) cfg.directPrefixes;
  ipv6Prefixes = lib.filter (lib.hasInfix ":") cfg.directPrefixes;

  # Destinations a listed user may still reach off the tunnel: what is never
  # routed to the internet anyway, plus directPrefixes. 200::/7 is
  # yggdrasil, 42::/16 retiolum.
  direct4 = [
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "255.255.255.255"
  ]
  ++ ipv4Prefixes;
  direct6 = [
    "::1"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
    "200::/7"
    "42::/16"
  ]
  ++ ipv6Prefixes;

  first = lib.head cfg.relays;
  registered = cfg.addresses != [ ];

  failover = pkgs.writeShellApplication {
    name = "mullvad-egress-failover";
    runtimeInputs = [ pkgs.wireguard-tools ];
    text = builtins.readFile ./failover.sh;
  };
in
{
  options.hyper.mullvadEgress = {
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users (static uid required) whose traffic may leave only through the Mullvad tunnel.";
    };
    addresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Tunnel addresses Mullvad assigned to the device. Empty (not yet
        registered): no tunnel, and the users get no internet at all.
      '';
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "WireGuard private key of the registered device, readable by systemd-network.";
    };
    relays = lib.mkOption {
      type = lib.types.nonEmptyListOf (
        lib.types.submodule {
          options = {
            endpoint = lib.mkOption {
              type = lib.types.str;
              description = "host:port";
            };
            publicKey = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      description = "Relays in failover order; the first is used at boot.";
    };
    directPrefixes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Public prefixes the users reach directly, bypassing the tunnel.";
    };
  };

  config = lib.mkIf (cfg.users != [ ]) (
    lib.mkMerge [
      {
        assertions = map (name: {
          assertion = config.users.users ? ${name} && config.users.users.${name}.uid != null;
          message = "hyper.mullvadEgress.users: '${name}' needs a static uid (uid rules and nftables match numbers).";
        }) cfg.users;

        networking.nftables.enable = true;
        networking.nftables.tables.mullvad-egress = {
          family = "inet";
          content = ''
            chain output {
              type filter hook output priority filter; policy accept;
              meta skuid { ${lib.concatMapStringsSep ", " toString uids} } jump tunneled
            }

            chain tunneled {
              oifname { "lo", "${iface}" } accept
              ip daddr { ${lib.concatStringsSep ", " direct4} } accept
              ip6 daddr { ${lib.concatStringsSep ", " direct6} } accept
              reject with icmpx no-route
            }
          '';
        };
      }

      (lib.mkIf registered {
        systemd.network.netdevs."50-${iface}" = {
          netdevConfig = {
            Name = iface;
            Kind = "wireguard";
            # Mullvad's own default: room for PPPoE and an IPv6 outer header.
            MTUBytes = "1380";
          };
          wireguardConfig.PrivateKeyFile = cfg.privateKeyFile;
          wireguardPeers = [
            {
              PublicKey = first.publicKey;
              Endpoint = first.endpoint;
              AllowedIPs = [
                "0.0.0.0/0"
                "::/0"
              ];
              RouteTable = table;
              # Keeps the NAT mapping open and, by forcing a handshake every
              # two minutes, tells the failover timer the relay is alive.
              PersistentKeepalive = 25;
            }
          ];
        };

        systemd.network.networks."50-${iface}" = {
          matchConfig.Name = iface;
          address = cfg.addresses;
          networkConfig.LinkLocalAddressing = "no";
          linkConfig.RequiredForOnline = "no";
          routingPolicyRules =
            map (prefix: {
              To = prefix;
              Table = "main";
              Priority = 5999;
            }) cfg.directPrefixes
            ++ lib.concatMap (uid: [
              {
                User = uid;
                Table = "main";
                SuppressPrefixLength = 0;
                Priority = 6000;
                Family = "both";
              }
              {
                User = uid;
                Table = table;
                Priority = 6001;
                Family = "both";
              }
            ]) uids;
        };

        # Replies inside the tunnel come from internet addresses that the
        # main table routes elsewhere; strict reverse-path checks (kernel and
        # nixos-fw) would drop them. WireGuard already authenticates them.
        boot.kernel.sysctl."net.ipv4.conf.${iface}.rp_filter" = 2;
        networking.firewall.extraReversePathFilterRules = ''
          iifname "${iface}" accept
        '';

        systemd.services.mullvad-egress-failover = lib.mkIf (lib.length cfg.relays > 1) {
          description = "Switch the Mullvad tunnel to the next relay when the current one is dead";
          after = [ "systemd-networkd.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.escapeShellArgs (
              [
                (lib.getExe failover)
                iface
              ]
              ++ lib.concatMap (r: [
                r.publicKey
                r.endpoint
              ]) cfg.relays
            );
          };
        };
        systemd.timers.mullvad-egress-failover = lib.mkIf (lib.length cfg.relays > 1) {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "3min";
            OnUnitActiveSec = "2min";
          };
        };
      })
    ]
  );
}
