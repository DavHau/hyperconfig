# ipv6-on-link <interface> <suffix> [expected-prefix]
#
# Prints <the /64 on <interface> right now>::<suffix>, e.g. for an address
# that lives in whatever prefix the router currently advertises. The /64 is
# taken from the interface's usable global addresses (not link-local, not
# ULA, not tentative, deprecated or failed DAD); exactly one /64 must be
# there, or it fails rather than guess. With expected-prefix (the first four
# groups the host was configured with) a different runtime prefix is
# reported as a warning, at journal warning level when run by systemd.
#
# IF_INET6 names another copy of /proc/net/if_inet6 (a dry run on another
# machine, fed that host's table).
import ipaddress
import os
import sys

IFA_F_DADFAILED = 0x08
IFA_F_DEPRECATED = 0x20
IFA_F_TENTATIVE = 0x40
ULA = ipaddress.ip_network("fc00::/7")

if len(sys.argv) not in (3, 4):
    sys.exit("usage: ipv6-on-link <interface> <suffix> [expected-prefix]")
iface, suffix = sys.argv[1], sys.argv[2]
expected = sys.argv[3] if len(sys.argv) == 4 else None

nets = set()
with open(os.environ.get("IF_INET6", "/proc/net/if_inet6")) as f:
    for line in f:
        hexaddr, _index, _plen, scope, flags, name = line.split()
        if name != iface or int(scope, 16) != 0:
            continue
        if int(flags, 16) & (IFA_F_DADFAILED | IFA_F_DEPRECATED | IFA_F_TENTATIVE):
            continue
        addr = ipaddress.IPv6Address(int(hexaddr, 16))
        if addr in ULA:
            continue
        nets.add(ipaddress.IPv6Network((addr, 64), strict=False))

if len(nets) != 1:
    found = ", ".join(sorted(map(str, nets))) or "none"
    sys.exit(f"ipv6-on-link: {iface}: need exactly one global /64, found {found}")
net = nets.pop()
addr = net[int(ipaddress.IPv6Address("::" + suffix.lstrip(":")))]

if expected is not None:
    want = ipaddress.IPv6Network(expected + "::/64")
    if want != net:
        level = "<4>" if "JOURNAL_STREAM" in os.environ else ""
        print(
            f"{level}WARNING: {iface} is in {net} now, but this host was "
            f"configured for {want}: everything addressed from the configured "
            f"prefix is unreachable until a redeploy with the new one; "
            f"publishing {addr}",
            file=sys.stderr,
        )
print(addr)
