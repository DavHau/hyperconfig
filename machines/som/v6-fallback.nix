# som carries amy's IPv6 on IPv4-only networks: an ip6ip6 tunnel over
# yggdrasil, out of br0 masqueraded to som's address
# (../../modules/nixos/v6-fallback).
{ config, ... }:
{
  imports = [ ../../modules/nixos/v6-fallback ];
  hyper.v6Fallback = {
    enable = true;
    role = "gateway";
    clients.amy.index = 1;
    # amy may reach what the internet reaches at som's public address
    # (teamclaude, the slots' SNI router, ssh): new connections to it pass
    # to the host firewall's interface-independent rules.
    publicSuffixes = [ config.networking.publicIPv6.token ];
  };
}
