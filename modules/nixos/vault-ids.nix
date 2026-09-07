# Principals of the vault NFS export, pinned to the same numeric ids on the
# server (bam) and every wg-vault client. The export is sec=sys, so a numeric
# uid/gid on a client IS the identity nfsd checks against bam's file modes;
# anything not pinned identically on both sides is meaningless as an ACL.
#
# Authorization on the pool is Unix modes plus one POSIX ACL, set once by
# hand on bam (not tmpfiles: the datasets are nofail mounts and a rule that
# ran against an unmounted /vault would chmod the XFS root's placeholder
# dirs). The datasets are acltype=posix; a default ACL `g:vault:rwx` on every
# directory makes files written by any writer group-writable regardless of
# that writer's umask:
#
#   setfacl -R -m g:vault:rwX -m d:g:vault:rwx <dir>
#
#   /vault, /vault/parquet            root:root  0755   traversal for everyone
#   /vault/parquet/depth, photos,
#     media, misc                      root:vault 2770   group writes, setgid so
#                                      new subdirs stay group vault; nothing
#                                      for others (momentum stays out)
#   /vault/parquet/momentum            momentum:vault 2775, files 664: momentum
#                                      and group vault write; readable by any
#                                      uid inside the wg-vault perimeter (its
#                                      hermes microVM, see momentum-state.nix)
#
# `vault` = read+write on the datasets. Members: dave (uid 1000 on bam/som/
# vit, 1001 on amy), grmpf (amy, uid 1000 - on the wire the same principal
# as dave elsewhere), stefan. The client sends its own gid list, so
# membership is granted per host. root on any client is root on the pool
# (no_root_squash, vault-nfs-server.nix). `momentum` = a single-purpose
# account whose only writable data is its own directory.
#
# 1100/1101 sit above the auto-allocated range in use (agent landed on 1002
# and already collides with stefan's pin on vit).
{
  users.groups.vault.gid = 1101;
  users.groups.momentum.gid = 1100;

  users.users.momentum = {
    isNormalUser = true;
    uid = 1100;
    group = "momentum";
    description = "momentum - /vault/parquet/momentum only";
  };
}
