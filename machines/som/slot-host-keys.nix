# ed25519 host keys of deployed container slots on som that are not in
# ../../modules/nixos/spaces/slots.nix (no mesh forward, no desktop alias),
# pinned for som's own clients (./dave-hermes-nmm.nix). The guest's own
# /etc/ssh key, not the host-provided bootstrap key. If one changes, the
# login fails closed until this is updated (ssh-keyscan the slot's v6 and
# compare with the guest's /etc/ssh/ssh_host_ed25519_key.pub).
{
  asof = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE3pjXmXbxgcPe6veVx5uRM4jzZ3wfeHOi/7mDqVmsdW";
}
