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
# Tested by the `zt-eu-lan-guard` flake check (./test.nix).
{ config, lib, ... }:
let
  cfg = config.hyper.ztEuLanGuard;
  net = import ../../../home-networks { inherit lib; };
  uids = map (name: config.users.users.${name}.uid) cfg.refusedUsers;
  v4 = lib.filter (p: !lib.hasInfix ":" p) net.routedLanPrefixes;
  v6 = lib.filter (lib.hasInfix ":") net.routedLanPrefixes;
in
{
  options.hyper.ztEuLanGuard.refusedUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Users (static uid required) refused every connection to the zt-eu sites' routed LANs.";
  };

  config = lib.mkIf (cfg.refusedUsers != [ ]) {
    assertions = map (name: {
      assertion = config.users.users ? ${name} && config.users.users.${name}.uid != null;
      message = "hyper.ztEuLanGuard.refusedUsers: '${name}' needs a static uid (nftables matches numbers).";
    }) cfg.refusedUsers;

    networking.nftables.enable = true;
    networking.nftables.tables.zt-eu-lan-guard = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid { ${lib.concatMapStringsSep ", " toString uids} } jump guarded
        }
        chain guarded {
          ${lib.optionalString (v4 != [ ]) "ip daddr { ${lib.concatStringsSep ", " v4} } jump refuse"}
          ${lib.optionalString (v6 != [ ]) "ip6 daddr { ${lib.concatStringsSep ", " v6} } jump refuse"}
        }
        chain refuse {
          meta l4proto tcp reject with tcp reset
          reject with icmpx admin-prohibited
        }
      '';
    };
  };
}
