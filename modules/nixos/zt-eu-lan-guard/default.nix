# Keeps listed users off the zt-eu sites' routed LANs (Roman's playa and
# casa, ../../../home-networks/sites.nix). Every zt-eu member gets routes to
# them, so without this any local user reaches their devices (ESPHome, Home
# Assistant, the routers' LuCI); mullvad-egress's kill switch does not stop
# it either (it passes 192.168.0.0/16 and fc00::/7, and its uid rule uses
# every non-default route of the main table). The prefixes come from
# home-networks; a listed user's connection to one is refused at once (TCP
# reset, else ICMP admin-prohibited), on any port. Everyone else (root,
# system services, users not listed) is untouched. Its own nftables table:
# no other table's accept can let a listed user's packet past it.
#
# `noLan` goes further for its users: no LAN at all, the host's own one
# included. Refused: every private, CGNAT, ULA and link-local range, the
# overlays (yggdrasil 200::/7, retiolum 42::/16: every fleet machine's open
# ports), multicast and broadcast, the home LAN's public v6 and its
# router's WAN link (home-networks' publicLanPrefixes) and
# `noLan.prefixes`. Passed: this host's own addresses (its services),
# replies on connections opened from outside (`ct state established`), the
# user's `noLan.allow` destinations, and the internet. sshd, when enabled,
# gives these users no forwarding of any kind (TCP, unix sockets, X11,
# agent, tunnels): defence in depth, as forwarded connections leave with
# the user's uid and meet the same rules.
#
# Tested by the `zt-eu-lan-guard` flake check (./test.nix).
{ config, lib, ... }:
let
  cfg = config.hyper.ztEuLanGuard;
  net = import ../../../home-networks { inherit lib; };
  uidOf = name: toString config.users.users.${name}.uid;
  uids = map uidOf cfg.refusedUsers;
  isV6 = lib.hasInfix ":";
  v4 = lib.filter (p: !isV6 p) net.routedLanPrefixes;
  v6 = lib.filter isV6 net.routedLanPrefixes;

  extra = cfg.noLan.prefixes ++ net.publicLanPrefixes;
  noLan4 = lib.unique (
    [
      "10.0.0.0/8"
      "100.64.0.0/10"
      "169.254.0.0/16"
      "172.16.0.0/12"
      "192.168.0.0/16"
      # multicast, limited broadcast (subnet broadcasts are in the above)
      "224.0.0.0/4"
      "255.255.255.255/32"
    ]
    ++ lib.filter (p: !isV6 p) extra
  );
  noLan6 = lib.unique (
    [
      "fc00::/7"
      "fe80::/10"
      "ff00::/8"
      # yggdrasil
      "200::/7"
      # tinc retiolum
      "42::/16"
    ]
    ++ lib.filter isV6 extra
  );

  # One allow entry: its destination (and TCP ports, if any) returns before
  # the refusal.
  allowRule =
    a:
    "${if isV6 a.address then "ip6" else "ip"} daddr ${a.address}"
    +
      lib.optionalString (a.ports != [ ])
        " tcp dport { ${lib.concatMapStringsSep ", " toString a.ports} }"
    + " return";
in
{
  options.hyper.ztEuLanGuard = {
    refusedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users (static uid required) refused every connection to the zt-eu sites' routed LANs.";
    };
    noLan = {
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Users (static uid required) refused every private, CGNAT, ULA,
          link-local, multicast, yggdrasil and retiolum destination, the
          home LAN's public v6 and `prefixes`, except this host's own
          addresses and their `allow` entries; no sshd forwarding.
        '';
      };
      prefixes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "2001:db8:1::/64" ];
        description = "Public prefixes that are LAN here too, beyond home-networks' publicLanPrefixes.";
      };
      allow = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.listOf (
            lib.types.submodule {
              options = {
                address = lib.mkOption {
                  type = lib.types.str;
                  description = "IPv4 or IPv6 address or prefix.";
                };
                ports = lib.mkOption {
                  type = lib.types.listOf lib.types.port;
                  default = [ ];
                  description = "These TCP ports only; empty: every port and protocol.";
                };
              };
            }
          )
        );
        default = { };
        description = "Per noLan user: destinations exempt from the refusal.";
      };
    };
  };

  config = lib.mkIf (cfg.refusedUsers != [ ] || cfg.noLan.users != [ ]) {
    assertions =
      map (name: {
        assertion = config.users.users ? ${name} && config.users.users.${name}.uid != null;
        message = "hyper.ztEuLanGuard: '${name}' needs a static uid (nftables matches numbers).";
      }) (cfg.refusedUsers ++ cfg.noLan.users)
      ++ map (name: {
        assertion = lib.elem name cfg.noLan.users;
        message = "hyper.ztEuLanGuard.noLan.allow.${name}: not in noLan.users.";
      }) (lib.attrNames cfg.noLan.allow);

    networking.nftables.enable = true;
    networking.nftables.tables.zt-eu-lan-guard = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          ${lib.optionalString (
            uids != [ ]
          ) "meta skuid { ${lib.concatStringsSep ", " uids} } jump guarded"}
          ${lib.concatMapStringsSep "\n  " (
            name: "meta skuid ${uidOf name} jump nolan_${uidOf name}"
          ) cfg.noLan.users}
        }
        chain guarded {
          ${lib.optionalString (v4 != [ ]) "ip daddr { ${lib.concatStringsSep ", " v4} } jump refuse"}
          ${lib.optionalString (v6 != [ ]) "ip6 daddr { ${lib.concatStringsSep ", " v6} } jump refuse"}
        }
      ''
      + lib.concatMapStrings (name: ''
        chain nolan_${uidOf name} {
          fib daddr type local return
          ct state established return
          ${lib.concatMapStringsSep "\n  " allowRule (cfg.noLan.allow.${name} or [ ])}
          ip daddr { ${lib.concatStringsSep ", " noLan4} } jump refuse
          ip6 daddr { ${lib.concatStringsSep ", " noLan6} } jump refuse
        }
      '') cfg.noLan.users
      + ''
        chain refuse {
          meta l4proto tcp reject with tcp reset
          reject with icmpx admin-prohibited
        }
      '';
    };

    # Forwarded connections already leave with the user's uid (sshd's
    # session process runs as the user) and meet the rules above; this
    # keeps -L/-R/-D, unix-socket, X11, agent forwarding and tunnels off
    # for these accounts anyway.
    services.openssh.extraConfig = lib.mkIf (cfg.noLan.users != [ ]) (
      lib.mkAfter ''
        Match User ${lib.concatStringsSep "," cfg.noLan.users}
          DisableForwarding yes
          PermitTunnel no
          PermitListen none
          PermitOpen none
        Match all
      ''
    );
  };
}
