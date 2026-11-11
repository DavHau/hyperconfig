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
#
# Retired slots, never reused: index 2, sshPort 2225, uids 1207/1208
# (the agave space, merged into geninf-space 2026-11-11). geninf-space
# took over gi-infra's slot (index 1, 2224, 1205/1206) with its keys.
{
  geninf-space = {
    machine = "som";
    index = 1;
    sshPort = 2224;
    uid = 1205;
    proxyUid = 1206;
  };
}
