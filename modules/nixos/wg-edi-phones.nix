# Phones on the wg-edi WireGuard mesh (edi is its controller): each phone
# is a peer of edi only, with one address in edi's /56, and edi lets it
# reach the mesh (fd73:d13c::/40 over wg-edi) and nothing else: no transit
# to the internet or edi's other interfaces (zt-eu, ygg, eth0).
#
# The phone's private key never leaves the phone: it is generated in the
# WireGuard app, and only its public key goes into `phones` below (read off
# the phone's screen). A phone whose publicKey is null gets its address
# and hosts entry but no peer on edi yet. Phone-side config and the steps
# Dave taps: docs/dave-phone.md.
#
# edi sets no persistent keepalive towards a phone (it would wake the
# phone's modem); the phone keeps its NAT mapping open itself
# (PersistentKeepalive in its config, docs/dave-phone.md).
#
# Imported on every wg-edi member through the instance's roles
# (modules/flake-parts/nixosConfigurations.nix): all of them get
# `<phone>.wg-edi` in /etc/hosts, edi also the peers and the forward guard.
{ config, lib, ... }:
let
  # Host suffix in edi's /56, from clan's allocator
  # (sha256(<name>)[:16], modules/clan/wireguard/ipv6_allocator.py), so it
  # never collides with a machine's.
  phones = {
    dave-phone = {
      suffix = "8d88:0f01:d622:4faf";
      publicKey = null;
    };
  };

  prefix = lib.removeSuffix "\n" (
    builtins.readFile ../../vars/per-machine/edi/wireguard-network-wg-edi/prefix/value
  );
  mesh = "fd73:d13c::/40";
  addr = p: "${prefix}:${p.suffix}";
  isController = config.networking.hostName == "edi";
  withKey = lib.filterAttrs (_: p: p.publicKey != null) phones;
  chain = "wg-edi-phones";
in
{
  assertions = [
    {
      # The guard below hard-codes the mesh prefix; fail loudly should the
      # wg-edi prefix ever move out of it.
      assertion = lib.hasPrefix "fd73:d13c:" prefix;
      message = "wg-edi-phones: edi's wg-edi prefix ${prefix} is outside ${mesh}";
    }
  ];

  networking.extraHosts = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: p: "${addr p} ${name}.wg-edi") phones
  );

  networking.wireguard.interfaces.wg-edi.peers = lib.mkIf isController (
    lib.mapAttrsToList (_: p: {
      inherit (p) publicKey;
      allowedIPs = [ "${addr p}/128" ];
    }) withKey
  );

  # edi's firewall is iptables (FORWARD policy ACCEPT, IPv6 forwarding on
  # for the mesh). Own chain, re-created on every firewall (re)start.
  networking.firewall.extraCommands = lib.mkIf isController ''
    ip6tables -w -N ${chain} 2>/dev/null || true
    ip6tables -w -F ${chain}
    ip6tables -w -D FORWARD -j ${chain} 2>/dev/null || true
    ip6tables -w -I FORWARD -j ${chain}
    ${lib.concatMapStrings (p: ''
      ip6tables -w -A ${chain} -s ${addr p} ! -o wg-edi -j DROP
      ip6tables -w -A ${chain} -s ${addr p} ! -d ${mesh} -j DROP
      ip6tables -w -A ${chain} -d ${addr p} ! -i wg-edi -j DROP
    '') (lib.attrValues phones)}
  '';
  networking.firewall.extraStopCommands = lib.mkIf isController ''
    ip6tables -w -D FORWARD -j ${chain} 2>/dev/null || true
    ip6tables -w -F ${chain} 2>/dev/null || true
    ip6tables -w -X ${chain} 2>/dev/null || true
  '';
}
