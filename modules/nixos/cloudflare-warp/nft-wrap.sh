# Stands in for /usr/sbin/nft inside warp-svc's mount namespace.
#
# warp-svc loads its leak-protection firewall (table inet cloudflare-warp)
# as `nft -f -`, falling back to `nft -f <tmpfile>`. That firewall drops
# everything leaving a physical interface except WARP's own tunnel, which
# kills overlay VPNs whose daemons pin their underlay sockets to the
# uplink (zerotier binds per interface, so its packets never enter the
# WARP route table) and, transitively, everything riding on them
# (yggdrasil peers over zerotier -> som.d).
#
# Rewrite: first rule of the input and output chains accepts packets
# whose socket belongs to a system service (system.slice). Routing is
# untouched, so unpinned traffic still goes through the tunnel; user
# sessions (user.slice) keep WARP's leak protection. system.slice always
# exists, so the rule never fails to load. Also accepted: the IPv6
# fallback's tunnel `v6fb` (../v6-fallback), which serves users' v6 while
# WARP is off or stuck connecting (its firewall is loaded before the
# connectivity checks pass). Interface-name matches load even while the
# link is absent. Anything else is passed through verbatim.
set -euo pipefail

if [[ $# -eq 2 && $1 == -f ]]; then
  src=$2
  if [[ $src == - ]]; then src=/dev/stdin; fi
  sed -E '/^[[:space:]]*type filter hook (input|output) priority 0; policy [a-z]+;$/a socket cgroupv2 level 1 "system.slice" accept\
oifname "v6fb" accept\
iifname "v6fb" accept' "$src" |
    nft -f -
  exit
fi

exec nft "$@"
