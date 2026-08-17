# NFSv4.2 export of bam's `vault` pool to amy/vit/som over the wg-vault
# WireGuard star (instance in modules/flake-parts/nixosConfigurations.nix:
# bam is the controller, endpoint = bam's LAN address, so peer traffic runs
# kernel WireGuard directly over the LAN).
#
# Authentication model: the export ACL is the wg-vault /56 subnet. An address
# in that subnet is reachable only through the wg-vault interface, and a peer
# gets onto that interface only by holding one of the three private keys in
# the instance's peer list - the WireGuard key list IS the mount ACL. sec=sys
# on top of that is fine: all members are single-admin machines with
# declarative UIDs.
#
# NFSv4-only keeps the surface to a single TCP port (2049); v3, UDP and the
# rpcbind/mountd port zoo stay off the wire.
{ config, ... }:
let
  # bam is the wg-vault controller; its prefix var defines the subnet.
  wgVaultSubnet = "${config.clan.core.vars.generators."wireguard-network-wg-vault".files.prefix.value}::/56";
in
{
  services.nfs.server = {
    enable = true;
    # /vault itself is a plain dir on the XFS root; crossmnt makes the zfs
    # dataset mounts beneath it (parquet, photos, media, misc) traversable.
    exports = "/vault ${wgVaultSubnet}(rw,crossmnt,no_subtree_check)";
  };

  # v4.2 only: no v3, no UDP.
  services.nfs.settings.nfsd = {
    vers3 = false;
    vers4 = true;
    "vers4.0" = false;
    "vers4.1" = false;
    "vers4.2" = true;
    udp = false;
  };

  # The dataset mounts are nofail and the pool import can lag or fail (see
  # ./machines/bam/zfs.nix hazards). Without this, nfsd would happily export
  # the empty mountpoint directories.
  systemd.services.nfs-server.unitConfig.RequiresMountsFor = [
    "/vault/parquet"
    "/vault/photos"
    "/vault/media"
    "/vault/misc"
  ];

  # The exports ACL above is the access gate; the port itself may be open.
  # (Reachable in practice only via wg-vault and other local interfaces.)
  networking.firewall.allowedTCPPorts = [ 2049 ];

  # Static secondary IPv4 on the LAN bridge: the wg-vault peers dial this as
  # their endpoint. The primary br0 address is a DHCP lease that has already
  # changed once (see machines/bam/inference-handoff.md), and the provider's
  # IPv6 prefix rotates - a fixed RFC1918 alias outside the router's DHCP
  # pool is the only address here that survives both. Merges into the
  # "40-br0" network unit defined in machines/bam/inference-net.nix.
  systemd.network.networks."40-br0".address = [ "192.168.8.250/24" ];
}
