# yggdrasil with a no-transit switch (`hyper.yggdrasil.noTransit`):
# a node with it on carries only its own traffic and never forwards
# other nodes' packets. Imported on every machine through the yggdrasil
# instance (modules/flake-parts/nixosConfigurations.nix), which also
# sets the fleet's multicast interfaces (./multicast-interfaces.nix).
#
# Why: yggdrasil is the fleet's one overlay ON TOP of the other VPNs
# (zt-eu, wg-edi, wg-vault, tailscale, hyprspace, LAN multicast): one
# stable address per machine, peered over every underlay, best link
# picked with fallback. That full mesh also made a roaming laptop on a
# 1 Mbit/s hotspot carry the fleet's traffic. yggdrasil 0.5.x has no
# option against that, so the package is patched:
#
#   - ./ironwood-no-transit.patch (the vendored router,
#     github.com/Arceliar/ironwood/network): `WithNoTransit`. In
#     router.handleTraffic, the one place a traffic packet arriving from
#     a peer is either handed to the local PacketConn or forwarded to the
#     next hop (`_lookup` -> `p.sendTraffic`), a no-transit node delivers
#     packets addressed to it and drops, silently, every other packet it
#     did not originate (decided by where the packet came from, a peer,
#     not by its source field, which the sending peer chooses). Routing
#     protocol messages take other paths
#     (peers.go: sig req/res, announce, bloom filter, path
#     lookup/notify/broken) and are untouched, so the node keeps its
#     place in the spanning tree and lookups still pass through it.
#   - ./yggdrasil-no-transit.patch: config key `NoTransit` ->
#     core.NoTransit -> iwn.WithNoTransit, logged at start.
#   Both apply with --fuzz=0: upstream drift fails the build.
#
# What ironwood does around a no-transit node (read from its source,
# checked in ./test.nix):
#   - A destination that is a direct peer is always reached over that
#     link: `_lookup` takes the peer whose tree distance to the
#     destination is smallest, and the destination itself has distance
#     0. So a no-transit node still talks to all its peers directly, and
#     two peers of it that are also peered directly never go through it.
#   - Between two nodes WITHOUT a direct link, the next hop is greedy in
#     tree space (strictly closer to the destination, then link cost).
#     If that hop is a no-transit node, the pair is blackholed: ironwood
#     does not route around a hop that drops (no feedback; a pathBroken
#     would not change the greedy choice either) until the tree itself
#     changes. Hence only machines that peer directly with everyone they
#     talk to may be no-transit (amy, joy: their peers are the whole
#     fleet over zt-eu and wg-edi, so their own traffic never needs
#     transit; nobody needs theirs).
#
# The package is used on every machine (one build); without the option
# it behaves exactly as upstream.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.yggdrasil;
in
{
  options.hyper.yggdrasil.noTransit = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Never forward other nodes' yggdrasil traffic (patched yggdrasil,
      see this file's header). Only for machines with a direct peering to
      every machine they talk to: a pair whose greedy path runs through a
      no-transit node is cut off until the tree changes.
    '';
  };

  config = {
    services.yggdrasil.package = pkgs.yggdrasil.overrideAttrs (old: {
      passthru = (old.passthru or { }) // {
        hyperNoTransit = true;
      };
      postPatch = (old.postPatch or "") + ''
        patch -p1 --fuzz=0 --forward < ${./yggdrasil-no-transit.patch}
      '';
      # The vendor dir is copied from goModules in configurePhase.
      postConfigure = (old.postConfigure or "") + ''
        chmod -R u+w vendor/github.com/Arceliar/ironwood
        patch -p1 --fuzz=0 --forward -d vendor/github.com/Arceliar/ironwood \
          < ${./ironwood-no-transit.patch}
      '';
    });
    services.yggdrasil.settings = lib.mkIf cfg.noTransit { NoTransit = true; };
    # yggdrasil ignores unknown config keys: an unpatched package (forced
    # elsewhere) would silently carry transit again.
    assertions = [
      {
        assertion = cfg.noTransit -> config.services.yggdrasil.package.hyperNoTransit or false;
        message = "hyper.yggdrasil.noTransit needs the patched yggdrasil package (modules/nixos/yggdrasil)";
      }
    ];
  };
}
