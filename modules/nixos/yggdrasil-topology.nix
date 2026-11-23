# Keeps roaming laptops off other machines' yggdrasil paths by making
# them leaves of som (peering topology). Imported on every machine
# through the yggdrasil instance (modules/flake-parts/nixosConfigurations.nix),
# which also narrows multicast discovery to physical LANs.
#
# Why: yggdrasil routes greedily over a spanning tree and has no
# "no-transit" flag, so a node peered with many others can end up on
# their paths. clan's yggdrasil service peers every machine with every
# other one over each VPN (zt-eu, wg-edi), plus multicast on all
# interfaces; amy on a 1 Mbit/s hotspot then carried the fleet's
# traffic. We use yggdrasil only as an overlay over overlays that
# already connect the peers, so the reach of a full mesh is not needed.
#
#   - A leaf (`leaves` below) dials only its upstream(s) over the
#     underlay addresses clan's service generated (zt-eu, wg-edi), has
#     no listener (Listen = [ ]) and no multicast (its
#     `multicastInterfaces = [ ]` in the inventory), so no other node can
#     peer with it. With a single upstream it can never sit between two
#     other nodes; it reaches the rest of the fleet through som.
#   - Every other machine drops the leaves from its static peers (clan
#     would dial them; with no listener there the dials only fail).
#   - Servers keep their full mesh (static peers over zt-eu/wg-edi,
#     multicast on physical LANs): transit through a server is fine.
#
# Not needed between machines sharing zt-eu at all (they could use the
# zt addresses); kept because the `<m>.d` names, ygg-pinned ACLs and the
# v6 fallback (./v6-fallback) rely on the yggdrasil addresses.
#
# The base peer list is clan's own (its definition of
# services.yggdrasil.settings, read through the option's definitions so
# the override is not self-referential); new VPN exports and new
# machines keep working without touching this file.
{
  config,
  lib,
  options,
  ...
}:
let
  # leaf -> the servers it peers with. One upstream: two would make the
  # leaf a possible path between them.
  leaves = {
    amy = [ "som" ];
    joy = [ "som" ];
  };

  self = config.clan.core.settings.machine.name;
  clanDir = config.clan.core.settings.directory;
  sharedVars = clanDir + "/vars/shared";

  # A machine's underlay addresses as they appear in clan's peer URLs:
  # its zerotier IPs (vars/shared/zerotier-ip-<m>-<instance>/ip) and the
  # `<m>.<instance>` names of the wireguard services.
  ztAddrs =
    m:
    lib.mapAttrsToList (n: _: lib.trim (builtins.readFile (sharedVars + "/${n}/ip/value"))) (
      lib.filterAttrs (
        n: t: t == "directory" && lib.hasPrefix "zerotier-ip-${m}-" n
          && builtins.pathExists (sharedVars + "/${n}/ip/value")
      ) (builtins.readDir sharedVars)
    );
  isPeerOf =
    m: url:
    lib.any (a: lib.hasInfix "[${a}]" url) (ztAddrs m) || builtins.match "[a-z]+://${m}\\..*" url != null;

  # clan's peers for this machine: every definition but this file's.
  basePeers = lib.concatMap (d: d.value.Peers or [ ]) (
    builtins.filter (
      d: !(lib.hasInfix "yggdrasil-topology.nix" d.file)
    ) options.services.yggdrasil.settings.definitionsWithLocations
  );

  isLeaf = leaves ? ${self};
  upstreamPeers = lib.filter (url: lib.any (m: isPeerOf m url) leaves.${self}) basePeers;
  nonLeafPeers = lib.filter (url: !lib.any (m: isPeerOf m url) (lib.attrNames leaves)) basePeers;
in
{
  config = lib.mkMerge [
    (lib.mkIf isLeaf {
      services.yggdrasil.settings = {
        # Its only path: retry within 30 s once the underlay is back
        # (yggdrasil's default backoff grows to ~1 h while offline).
        Peers = lib.mkForce (
          map (u: u + (if lib.hasInfix "?" u then "&" else "?") + "maxbackoff=30s") upstreamPeers
        );
        Listen = lib.mkForce [ ];
      };
      assertions = [
        {
          assertion = upstreamPeers != [ ];
          message = "yggdrasil-topology: leaf ${self} found no peer URL for its upstream(s) ${toString leaves.${self}}";
        }
      ];
    })
    (lib.mkIf (!isLeaf) {
      services.yggdrasil.settings.Peers = lib.mkForce nonLeafPeers;
    })
  ];
}
