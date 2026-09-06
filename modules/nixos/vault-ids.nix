# Principals of the vault NFS export, pinned to the same numeric ids on the
# server (bam) and every wg-vault client. The export is sec=sys, so a numeric
# uid/gid on a client IS the identity nfsd checks against bam's file modes;
# anything not pinned identically on both sides is meaningless as an ACL.
#
# Authorization on the pool is plain Unix modes, set once by hand on bam
# (not tmpfiles: the datasets are nofail mounts and a rule that ran against
# an unmounted /vault would chmod the XFS root's placeholder dirs):
#
#   /vault, /vault/parquet            root:root  0755   traversal for everyone
#   /vault/parquet/depth, photos,
#     media, misc                      root:vault 0750   readers only
#   /vault/parquet/momentum            momentum:vault 2755, files 644: momentum
#                                      writes; readable by any uid inside the
#                                      wg-vault perimeter (its hermes microVM
#                                      reads arrive as squashed root, see
#                                      momentum-state.nix)
#
# `vault` = read access to the datasets (dave, stefan; grmpf on amy, where
# uid 1000 is grmpf). `momentum` = a single-purpose account whose only
# writable data is its own directory.
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
