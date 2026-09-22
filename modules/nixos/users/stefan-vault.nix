# stefan on the wg-vault client machines (som, vit): SSH login plus read-only
# access to bam's /vault/parquet mounted at /vault (vault-nfs-client.nix).
#
# The NFS export uses sec=sys, so the UID on the client IS the identity on
# bam. Pin it so stefan is the same principal on every wg-vault client
# (dave holds 1000 per modules/nixos/common.nix, 1001 on amy — 1002 is the
# first UID free everywhere). Read access comes from the `vault-ro` group
# (tiers and modes documented in ../vault-ids.nix).
#
# nas imports ../users/stefan.nix directly and is deliberately NOT switched
# to this module: stefan already exists there with a live UID, and userborn
# refuses to renumber existing accounts.
{
  imports = [ ./stefan.nix ];

  users.users.stefan.uid = 1002;
  users.users.stefan.extraGroups = [ "vault-ro" ];
}
