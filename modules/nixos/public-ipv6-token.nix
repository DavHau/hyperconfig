# A stable, hand-picked IPv6 suffix on the LAN uplink, so the host has a
# predictable public address in whatever /64 the AIS router advertises.
#
# The home LAN is one provider /64 (currently 2405:9800:b901:94e3::/64), relayed
# by the GL.iNet from the AIS ZTE; no prefix delegation, no NAT6. Inbound is
# blocked by the ZTE's IPv6 firewall unless a per-address allow rule exists —
# added with the repo's `router-ais ipv6-rules add` (tools/router-ais). The
# rule is keyed on the full address, so the suffix must not depend on the MAC
# (SLAAC) or rotate (privacy extensions). A static token keeps the suffix
# fixed while still following the advertised prefix; only the router rule
# needs an update if the provider ever changes the /64.
#
# Where the token has to live: networkd. clan sets networking.useNetworkd, and
# nixos-facter turns each detected NIC into a 40-<iface>.network with DHCP=yes,
# so networkd processes the RAs in userspace (it sets accept_ra=0 on the link)
# and forms the SLAAC addresses itself. The token address therefore comes
# from [IPv6AcceptRA] Token=, next to the stable-privacy and temporary
# addresses networkd keeps adding. NetworkManager runs beside networkd on the
# same link (spaces desktop profile) and adds its own addresses too; it never
# sees the RA prefix through the kernel, so an NM-side token would be inert.
# Same idea as the inference VM's ::feed:da7a on bam (inference-net.nix),
# minus the NDP proxy.
{ config, lib, ... }:
let
  cfg = config.networking.publicIPv6;
in
{
  options.networking.publicIPv6 = {
    token = lib.mkOption {
      type = lib.types.str;
      example = "::c0de:ba5e";
      description = "Interface-id half of the public address; the RA prefix supplies the rest.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      example = "enp6s0";
      description = "The uplink link; needs a 40-<interface>.network (nixos-facter's for a NIC, or container-slots.nix's bridge).";
    };
  };

  config = {
    assertions = [
      {
        assertion = config.systemd.network.networks ? "40-${cfg.interface}";
        message = "networking.publicIPv6.interface: no 40-${cfg.interface}.network unit on this host";
      }
    ];
    systemd.network.networks."40-${cfg.interface}".ipv6AcceptRAConfig.Token = "static:${cfg.token}";
  };
}
