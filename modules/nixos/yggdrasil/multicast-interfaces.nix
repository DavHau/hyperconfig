# The fleet's yggdrasil MulticastInterfaces (clan's yggdrasil service
# setting `multicastInterfaces`, set in modules/flake-parts/nixosConfigurations.nix):
# clan's default (every interface, overlays at a worse priority) minus
# the interfaces that are never an underlay: container and VM veths and
# bridges (ve-*, veth*, vb-*, vnet*, docker*, br-*, podman*, virbr*,
# cni*, lxcbr*; som's br0 LAN stays),
# yggdrasil's own ygg and lo.
#
# yggdrasil (0.5.x) matches each entry's Regex with Go's RE2 (no
# lookahead), skips an entry with Beacon and Listen off instead of
# stopping there, and walks its entries in map order (random), so an
# exclusion can't be its own entry and overlapping entries pick their
# priority at random. Hence two disjoint entries: the overlays, and a
# regex for "starts with none of these prefixes" built below.
#
# Note: yggdrasil ignores point-to-point interfaces for multicast
# (tailscale0, hyprspace, wg-*), so of the overlays only zerotier (zt*)
# carries multicast peerings; the others are listed for completeness.
{ lib }:
let
  overlays = [
    "zt"
    "wg"
    "tailscale"
    "hyprspace"
    "mycelium"
    "tinc"
    "tun"
    "tap"
  ];
  never = [
    "ve-"
    "veth"
    "vb-"
    "vnet"
    "docker"
    "br-"
    "podman"
    "virbr"
    "cni"
    "lxcbr"
    "ygg"
    "lo"
  ];

  # A regex matching (from the start) every name that begins with none of
  # `ps`: a walk down the prefixes' trie. At node `s`: end of name or a
  # character no prefix continues with accepts; a character that
  # completes a prefix rejects; any other one descends.
  notStartingWith =
    ps:
    let
      node =
        s:
        let
          n = builtins.stringLength s;
          kids = lib.unique (
            map (p: builtins.substring n 1 p) (builtins.filter (p: lib.hasPrefix s p && p != s) ps)
          );
          # '-' first, so it is literal in the bracket.
          cls = lib.concatStrings (lib.sort (a: b: a == "-" || (b != "-" && a < b)) kids);
          alts = map (c: "|" + c + node (s + c)) (builtins.filter (c: !(builtins.elem (s + c) ps)) kids);
        in
        "($|[^${cls}]${lib.concatStrings alts})";
    in
    "^" + node "";

  overlayRegex = "^(${lib.concatStringsSep "|" overlays})";
  otherRegex = notStartingWith (never ++ overlays);

  # Evaluated once: the regexes behave on real interface names (POSIX ERE
  # here; the constructs used are the same in RE2).
  matches = re: name: builtins.match (re + ".*") name != null;
  samples = {
    other = [
      "enp6s0"
      "eth0"
      "end0"
      "wlp7s0"
      "wlo1"
      "br0"
      "usb0"
      "wwan0"
      "enx001122334455"
      "bond0"
      "v"
      "vlan10"
      "ve"
      "d"
      "dock"
      "b"
      "brx"
      "t"
    ];
    overlay = [
      "ztxwywyczu"
      "zt44xbwxfb"
      "tailscale0"
      "hyprspace"
      "wg-edi"
      "wg-vault"
    ];
    none = [
      "ve-infra-space"
      "vb-asof"
      "vnet0"
      "veth1234"
      "docker0"
      "br-inf"
      "br-"
      "podman0"
      "virbr0"
      "cni0"
      "lxcbr0"
      "ygg"
      "lo"
    ];
  };
  bad =
    builtins.filter (n: !(matches otherRegex n) || matches overlayRegex n) samples.other
    ++ builtins.filter (n: !(matches overlayRegex n) || matches otherRegex n) samples.overlay
    ++ builtins.filter (n: matches otherRegex n || matches overlayRegex n) samples.none;
in
assert lib.assertMsg (bad == [ ])
  "yggdrasil multicast regexes misclassify: ${toString bad} (${otherRegex})";
[
  {
    # Overlays at a worse priority, so a direct LAN link to the same peer wins.
    Regex = overlayRegex;
    Beacon = true;
    Listen = true;
    Port = 5400;
    Priority = 10;
  }
  {
    Regex = otherRegex;
    Beacon = true;
    Listen = true;
    Port = 5400;
  }
]
