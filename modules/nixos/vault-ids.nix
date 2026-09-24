# Principals of the vault NFS export, pinned to the same numeric ids on the
# server (bam) and every wg-vault client. The export is sec=sys, so a numeric
# uid/gid on a client IS the identity nfsd checks against bam's file modes;
# anything not pinned identically on both sides is meaningless as an ACL.
#
# Two tiers:
#   `vault`    (gid 1101) read+write on the datasets. Members: dave (uid 1000
#              on bam/som/vit, 1001 on amy), grmpf (amy, uid 1000 - on the
#              wire the same principal as dave elsewhere).
#   `vault-ro` (gid 1103) read-only on /vault/parquet. Members: stefan,
#              momentum, hsjobeki, dave-hermes, egg, pinpox - each user's own
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
#
# When adding readers to an existing tree, set the ACL before closing the
# modes, or the readers lose access in between.
#
# 1100-1104 sit above the auto-allocated range in use (agent landed on 1002
# and already collides with stefan's pin on vit): 1100 momentum, 1101 vault,
# 1102 hsjobeki (users/hsjobeki-vault.nix), 1103 vault-ro, 1104 pinpox
# (machines/som/hermes-agents.nix). gid 1100 was the retired `momentum` primary group and
# stays unallocated so a stale gid on a forgotten file never maps to a new
# group.
{
  users.groups.vault.gid = 1101;
  users.groups.vault-ro.gid = 1103;

  users.users.momentum = {
    isNormalUser = true;
    uid = 1100;
    description = "momentum - read-only vault consumer";
    extraGroups = [ "vault-ro" ];
  };
}
