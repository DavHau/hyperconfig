# SSH login for the momentum account (identity in ../vault-ids.nix) on a
# wg-vault client. Currently dave's admin keys (the clan admin role fills
# root's list); swap in the consumer's own key when they have one.
{ config, ... }:
{
  users.users.momentum.openssh.authorizedKeys.keys =
    config.users.users.root.openssh.authorizedKeys.keys;
}
