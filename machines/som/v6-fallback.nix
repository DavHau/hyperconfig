# som carries amy's IPv6 on IPv4-only networks: an ip6ip6 tunnel over
# yggdrasil, out of br0 masqueraded to som's address
# (../../modules/nixos/v6-fallback).
{
  imports = [ ../../modules/nixos/v6-fallback ];
  hyper.v6Fallback = {
    enable = true;
    role = "gateway";
    clients.amy.index = 1;
  };
}
