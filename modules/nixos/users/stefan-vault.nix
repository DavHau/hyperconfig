# stefan on the wg-vault client machines (som, vit): SSH login plus read
# access to bam's vault datasets mounted at /vault (vault-nfs-client.nix).
#
# The NFS export uses sec=sys, so the UID on the client IS the identity on
# bam. Pin it so stefan is the same principal on every wg-vault client
# (dave holds 1000 per modules/nixos/common.nix, 1001 on amy — 1002 is the
# first UID free everywhere). Read access to /vault/parquet then follows
# from the dataset's other-read file modes on bam.
#
# nas imports ../users/stefan.nix directly and is deliberately NOT switched
# to this module: stefan already exists there with a live UID, and userborn
# refuses to renumber existing accounts.
{
  imports = [ ./stefan.nix ];

  users.users.stefan.uid = 1002;
}
