# IPv6 for amy on IPv4-only networks

Dave (2026-11-22): "The Cloudflare WARP button doesn't seem to work on
amy... The main goal is to get IPv6 on a non-v6 Wi-Fi." Decided: the
fallback through som is the default (exit via som's address accepted);
WARP stays an option on the bar button and takes over while connected.

## Design

- `modules/nixos/v6-fallback` (header has the details): ip6ip6 tunnel
  amy `v6fb` <-> som `v6fb-amy` over yggdrasil (works where UDP is
  blocked), fd99:6fb:0:1::/64, NAT66 out of som's br0. amy routes only
  local users' sockets (uid 1000-29999) and the spaces' veths (fwmark
  0x80000000) into it, by an ip rule after main: overlay daemons (root,
  yggdrasil's DynamicUser) never enter it, native v6 and WARP win.
  Health tick every 10 s; 3 silent probes withdraw it (fail fast) and
  hold it off 5 min.
- `modules/nixos/cloudflare-warp`: the toggle connects in `tunnel_only`
  (WARP's DNS mode can't pass its own check beside encrypted-dns), its
  ip rule is no longer deleted by networkd, and `warp-mesh-guard`
  disconnects WARP if som and edi stop answering over yggdrasil while it
  is on (only where the mesh worked before).
- Test: `checks.x86_64-linux.v6-fallback` (VM: v4-only client, mesh
  survives, daemons outside, containers, spoofing, WARP/native
  precedence, failover).

## Status

| step | state |
|---|---|
| WARP root cause | done (DNS check vs nss-resolve; networkd deleting rule 5209) |
| v6-fallback module + VM test | done, test green, mutation-checked |
| security review | 1st: request-changes (proto-41 spoof via conntrack) -> fixed; fresh delta review: approve-with-nits, nits applied |
| land on main | done |
| deploy amy, then som | parent; amy offline (hotfix incident), a reboot clears its hotfix side |
| live verification on amy | after deploy (commands below) |

## Live checks (amy)

    systemctl list-timers v6-fallback warp-mesh-guard
    journalctl -u v6-fallback -n 20
    ip -6 rule show priority 32800; ip -6 route show table 6464
    runuser -u grmpf -- curl -6 -s https://ifconfig.co   # som's v6
    curl -6 -m5 https://ifconfig.co                      # root: no route (by design)
    ping -c3 som.d
    warp-toggle toggle; warp-cli --accept-tos status; runuser -u grmpf -- curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp=
