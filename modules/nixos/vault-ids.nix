# Principals of the vault NFS export, pinned to the same numeric ids on the
# server (bam) and every wg-vault client. The export is sec=sys, so a numeric
# uid/gid on a client IS the identity nfsd checks against bam's file modes;
# anything not pinned identically on both sides is meaningless as an ACL.
#
# Three tiers:
#   `vault`    (gid 1101) read+write on the datasets. Members: dave (uid 1000
#              on bam/som/vit, 1001 on amy), grmpf (amy, uid 1000 - on the
#              wire the same principal as dave elsewhere).
#   `vault-parquet-rw` (gid 1107) read+write on /vault/parquet only.
#              Members: slot-asof, slot-mm (som; the asof and mm container
#              slots' shares, machines/som/configuration.nix).
#   `vault-ro` (gid 1103) read-only on /vault/parquet. Members: stefan,
#              momentum, hsjobeki, dave-hermes, egg, pinpox, adam, j, willi, domi, rti, chris, b3x, joe, daniel, voice - each user's own
#              module adds the group (users/*-vault.nix, *-hermes.nix).
# The client sends its own gid list, so membership is granted per host: a
# reader reads from every wg-vault client whose config imports its module.
# root on any client is root on the pool (no_root_squash,
# vault-nfs-server.nix).
#
# Authorization on the pool is Unix modes plus POSIX ACLs, set by hand on
# bam (not tmpfiles: the datasets are nofail mounts and a rule that ran
# against an unmounted /vault would chmod the XFS root's placeholder dirs;
# and the layout below /vault/parquet is data, not this repo's business).
# The datasets are acltype=posix. Rule: /vault (a plain dir on bam's XFS
# root) is root:root 0755, traversal only - nothing is written there; every
# dataset mountpoint and every tree below grants g:vault rwx plus a default
# ACL (media/misc/photos: root:vault 2770; parquet keeps "other" r-x), so
# files written by any writer come out group-writable and reader-readable
# regardless of umask. Keep secrets off /vault entirely: the recursive
# setfacl below re-grants readers on every file, whatever its mode.
#
#   setfacl -R -m g:vault:rwX -m d:g:vault:rwx <tree>          # any dataset
#   setfacl -R -m g:vault-ro:rX -m d:g:vault-ro:rx <tree>      # /vault/parquet
#   setfacl -R -m g:vault-parquet-rw:rwX -m d:g:vault-parquet-rw:rwx <tree>
#
# When adding readers to an existing tree, set the ACL before closing the
# modes, or the readers lose access in between.
#
# Exception: /vault/misc/scans (bam's scan page, modules/nixos/scan-trigger)
# is Dave's alone: dave 0700/0600 and no ACLs. Leave it out of a recursive
# setfacl over /vault/misc; if one runs anyway, scan-deliver strips the ACLs
# again on its hourly sweep.
#
# /vault/parquet's "other" r-x lets any uid read most of it. Agents kept
# off the vault (`vault = false`, machines/som/hermes-agents-data.nix, and
# the agents of machines/som/hermes-agents.nix that are not in that file)
# therefore get a named-user deny on the pool root, which blocks every
# dataset below it. They are listed in `hyper.vaultIds.deniedUsers` below
# (som asserts that every such agent is, with its uid); on bam, for each:
#
#   setfacl -m u:<uid>:--- /vault
#
# Applied by hand, like the ACLs above (/vault's datasets are nofail
# mounts); `getfacl /vault` on bam shows what is applied.
#
# Pinned ids: 1002 stefan, 1004 egg, 1005 dave-hermes, 1100 momentum,
# 1101 vault (gid), 1102 hsjobeki, 1103 vault-ro (gid), 1104 pinpox,
# 1105 adam, 1106 j, 1107 vault-parquet-rw (gid), 1108 willi, 1109 domi, 1110 rti, 1111 chris, 1112 b3x, 1113 joe,
# 1114 thaigersprint (no vault access, denied above), 1115 (was bumper,
# retired, do not reuse), 1116 roman (som's
# Home Assistant agent, no vault access, denied above), 1117 daniel,
# 1118 daniel-meli (no vault access, denied above), 1119 voice (the Voice
# PE's untrusted agent, modules/nixos/voice-gateway),
# 1200 agent,
# 1201 slot-asof, 1202 slot-mm, 1203 infra (uid and gid; the infra-space
# container's user, no host account: infra-space/default.nix; on members
# the gid is also the memberless host group infra-space-gcroot,
# infra-space/gcroots.nix; not a vault
# principal, only kept clear of host users because it owns the container's
# home on the host), 1204 infra-space-ssh (uid and gid; the members' system
# user forwarding to the container's sshd, pinned for the host's nftables
# owner gate: infra-space/default.nix; not a vault principal), 1205
# geninf-space (was gi-infra) and 1206 geninf-space-ssh, 1207/1208 (were
# agave and agave-ssh, retired, do not reuse) (the same pair for the
# named spaces on som: each space's container user, owning its home
# under /var/lib/spaces, and its sshd forwarder there;
# spaces/registry.nix; not vault principals), 1209 voice-gateway (uid and
# gid; som's Voice PE router, modules/nixos/voice-gateway; not a vault
# principal), 1214 the voice desktop space's user `hermes` (uid and gid;
# owns its home on amy, hermes-desktop-spaces.nix; not a vault
# principal). gid 1100 stays unallocated.
{ lib, ... }:
{
  options.hyper.vaultIds.deniedUsers = lib.mkOption {
    type = lib.types.attrsOf lib.types.int;
    readOnly = true;
    description = ''
      uids with a named-user deny ACL on bam's /vault (name -> uid), set
      by hand (see the header). Data for checks only: nothing applies it.
    '';
  };

  config.hyper.vaultIds.deniedUsers = {
    thaigersprint = 1114;
    roman = 1116;
    daniel-meli = 1118;
  };

  config.users.groups.vault.gid = 1101;
  config.users.groups.vault-ro.gid = 1103;
  config.users.groups.vault-parquet-rw.gid = 1107;

  config.users.users.momentum = {
    isNormalUser = true;
    uid = 1100;
    description = "momentum - read-only vault consumer";
    extraGroups = [ "vault-ro" ];
  };
}
