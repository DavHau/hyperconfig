# A stable, hand-picked IPv6 suffix on the home-wifi uplink, so the host has a
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
# The uplink is the clan wifi-home profile (`home`, NetworkManager); the wired
# NIC is unplugged and networkd-managed, so a cable would need the same token
# on its 40-<iface>.network unit instead. Same idea as the inference VM's
# ::feed:da7a on bam (inference-net.nix), minus the NDP proxy.
{ config, lib, ... }:
{
  options.networking.publicIPv6Token = lib.mkOption {
    type = lib.types.str;
    example = "::c0de:ba5e";
    description = "Interface-id half of the public address; the RA prefix supplies the rest.";
  };

  config.networking.networkmanager.ensureProfiles.profiles.home.ipv6 = {
    method = "auto"; # NM rejects an [ipv6] section without it
    addr-gen-mode = "eui64"; # token only applies in this mode
    token = config.networking.publicIPv6Token;
  };
}
