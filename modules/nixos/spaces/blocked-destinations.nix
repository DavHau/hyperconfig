# What a confined space's guest may not reach (./host.nix `confine`):
# yggdrasil, retiolum, ULA (the LANs' v6, zerotier, the other spaces and
# infra-space), RFC 1918, CGNAT, link-local. Used by ./default.nix and
# ../dave-desktop/isolated-apps.nix.
{
  v4 = [
    "10.0.0.0/8"
    "100.64.0.0/10"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
  v6 = [
    # yggdrasil
    "200::/7"
    # retiolum
    "42::/16"
    "fc00::/7"
    "fe80::/10"
  ];
}
