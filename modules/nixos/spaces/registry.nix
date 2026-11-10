# The named agent spaces (./default.nix): which machine runs each, the
# port on that machine's yggdrasil address that reaches the space's sshd,
# its veth subnet and its ids. Plain data: the host (./default.nix) and
# Dave's desktops (./client.nix: launchers, pinned host keys, herdr
# machines) read it, never another machine's evaluated config.
#
#   index     the veth subnet: v4 10.235.0.<4i>/30 (this host .<4i+1>,
#             the guest .<4i+2>), v6 fd23:5ace:0:<i>::/64 (::1, ::2).
#             0 is infra-space's (10.235.0.0/30, fd23:5ace::/64).
#   sshPort   2222 is the unlock initrd's sshd, 2223 infra-space's
#             (../infra-space/members.nix).
#   uid       the guest user's uid and gid (it owns the space's home on
#             the host); proxyUid the host's sshd forwarder. Id ladder in
#             ../vault-ids.nix; no host user has either.
#
# The guest's user is the space's name; its container is named after the
# space too (at most 12 characters: the host's veth is ve-<name>).
{
  gi-infra = {
    machine = "amy";
    index = 1;
    sshPort = 2224;
    uid = 1205;
    proxyUid = 1206;
  };
  agave = {
    machine = "amy";
    index = 2;
    sshPort = 2225;
    uid = 1207;
    proxyUid = 1208;
  };
}
