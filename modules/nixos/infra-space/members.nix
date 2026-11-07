# The machines that run an infra-space container (./default.nix), and the
# port on the machine's yggdrasil address that reaches the container's
# sshd. Plain data: every machine that needs the list imports this file;
# addresses and host keys come from the members' public clan vars, never
# from another machine's evaluated config. 2222 is the unlock initrd's
# sshd (../initrd-ssh.nix, ../zfs-remote-unlock): a different host key on
# the same port would confuse clan-unlock's pinned known_hosts.
{
  som.sshPort = 2223;
  amy.sshPort = 2223;
}
