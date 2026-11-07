# What ./sites.nix implies for zt-eu: its network id, the routers' zt
# addresses, the controller's routes, and each router's state for
# ./apply.py. Consumed by ../modules/nixos/zt-eu-sites.nix (edi),
# ../modules/flake-parts/nixosConfigurations.nix (allowedIds) and
# ../modules/flake-parts/apps.site-routers-apply.nix.
{ lib }:
let
  data = import ./sites.nix;
  inherit (data.zerotier) instance ipv4;

  networkId = lib.removeSuffix "\n" (
    builtins.readFile ../vars/shared/zerotier-network-${instance}/network-id/value
  );

  # ZeroTier's rfc4193 address of a member: fd, the network id, 9993, the
  # node id (the same layout clan's zerotier-ip vars hold).
  rfc4193 =
    nodeId:
    let
      hex = "fd${networkId}9993${nodeId}";
    in
    lib.concatMapStringsSep ":" (i: builtins.substring (i * 4) 4 hex) (lib.range 0 7);
  rfc4193Prefix =
    let
      hex = "fd${networkId}99930000000000";
    in
    lib.concatMapStringsSep ":" (i: builtins.substring (i * 4) 4 hex) (lib.range 0 5) + "::/88";

  sites = lib.mapAttrs (
    _: site:
    site
    // {
      router = site.router // {
        ztIpv6 = rfc4193 site.router.ztNodeId;
      };
    }
  ) data.sites;

  routedSites = lib.filter (s: s.routeLan) (lib.attrValues sites);

  # Prefixes a site's LAN can be reached from over zt-eu: zt-eu itself and
  # the other sites' routed LANs.
  remotePrefixes =
    self:
    [
      ipv4.subnet
      rfc4193Prefix
    ]
    ++ lib.concatMap (
      s:
      lib.optionals (s.router.name != self.router.name) (
        [ s.lan.ipv4 ] ++ lib.optional (s.lan.ipv6 != null) s.lan.ipv6
      )
    ) routedSites;
in
{
  inherit
    instance
    networkId
    ipv4
    rfc4193Prefix
    sites
    ;

  routers = lib.mapAttrsToList (_: s: s.router) sites;

  # The controller's `routes`: zt-eu's own IPv4 on-link, then each routed
  # site's LAN via its router.
  routes = [
    {
      target = ipv4.subnet;
      via = null;
    }
  ]
  ++ lib.concatMap (
    s:
    [
      {
        target = s.lan.ipv4;
        via = s.router.ztIpv4;
      }
    ]
    ++ lib.optional (s.lan.ipv6 != null) {
      target = s.lan.ipv6;
      via = s.router.ztIpv6;
    }
  ) routedSites;

  # One router's state as ./apply.py converges it (rendered to JSON).
  routerState =
    adminKeys: site:
    let
      r = site.router;
    in
    {
      inherit (r)
        name
        address
        ztNodeId
        ztIpv4
        ztIpv6
        firewall
        zerotierSection
        passwordVar
        ;
      inherit networkId adminKeys;
      inherit (site) masqueradeFromLan;
      # Sources to masquerade into the LAN, or none.
      masqueradeToLan = if site.masqueradeToLan then remotePrefixes site else [ ];
    };
}
