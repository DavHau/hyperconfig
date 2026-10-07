# router-cm-beryl

CLI for the GL.iNet Beryl AX (GL-MT3000, OpenWrt with fw3) that sits between
the AIS ZTE (`192.168.1.1`, managed by `tools/router-ais`) and the home LAN.
It manages the IPv6 *wan -> lan* allow rules in `/etc/config/firewall` over
ssh + `uci`, and installs the LAN IPv6 fallback (below). Built as
`packages.router-cm-beryl` from `modules/flake-parts/router-cm-beryl.nix` and
included in the default devshell.

```
router-cm-beryl [--host 192.168.8.1] [-J USER@HOST] [--json] [-v] info
router-cm-beryl ipv6-rules list
router-cm-beryl ipv6-rules add --address <ipv6> [--proto all|tcp|udp|tcpudp] [--port N|N-M] [--name NAME]
router-cm-beryl ipv6-rules delete <section|name> [--i-know]
router-cm-beryl lan6-fallback install [--prefix <ipv6>/64]
router-cm-beryl lan6-fallback status
```

The Beryl LAN (`192.168.8.0/24`) is usually not reachable from a laptop on the
ZTE wifi; jump through a host on that LAN with `-J root@bam.d` (plain ssh
`ProxyJump`, so the jump hop uses your normal ssh keys and config).

Examples:

```
$ router-cm-beryl -J root@bam.d info
GL.iNet GL-MT3000 (glinet,mt3000-snand) hostname GL-MT3000
GL firmware 4.8.1, OpenWrt 21.02-SNAPSHOT, kernel 5.4.211
firewall: fw3
zones:
name      networks       input   output  forward
lan       lan            ACCEPT  ACCEPT  ACCEPT
wan       wan,wan6,wwan  DROP    ACCEPT  REJECT
guest     guest          REJECT  ACCEPT  REJECT
zerotier  zerotier       ACCEPT  ACCEPT  REJECT

$ router-cm-beryl -J root@bam.d ipv6-rules list
section              name                  on   src  dest  family  dest_ip                         proto   dport            target
...
cfg2692bd            Allow-inference-v6    yes  wan  lan   ipv6    2405:9800:b901:94e3::feed:da7a  tcp     22 80 443 30000  ACCEPT
cfg2792bd            som                   yes  wan  lan   ipv6    2405:9800:b901:94e3::feed:50e   all     -                ACCEPT

$ router-cm-beryl -J root@bam.d ipv6-rules add --address 2405:9800:b901:94e3::feed:50e --name som
added cfg2792bd som: all -> 2405:9800:b901:94e3::feed:50e port any

$ router-cm-beryl -J root@bam.d ipv6-rules delete som
deleted cfg2792bd som
```

`add` appends an anonymous `config rule` section with `src=wan`, `dest=lan`,
`family=ipv6`, `dest_ip=<address>`, `target=ACCEPT`, commits it and runs
`/etc/init.d/firewall reload` (`fw3 reload`; existing connections survive).
**The intended default is all ports and protocols**: the exposed host's own
NixOS firewall is the port authority, the same model as the `inference` rule
on the ZTE. `--proto` / `--port` exist for deliberately narrower rules;
`--port` needs `--proto tcp|udp|tcpudp`. The default name is
`omp-<last 4 hex of the address>`; a name that already exists is refused.

`list` shows every `firewall.rule` with `src=wan` and family `ipv6` or unset
(any), including the stock OpenWrt/GL rules, in uci order. The `section`
column is the uci section id (`cfg...` for anonymous sections) and is the
stable handle for `delete`.

`delete` accepts the section id or the name. It refuses to delete a rule whose
`dest_ip` covers `2405:9800:b901:94e3::feed:da7a` (the inference VM's live
demo) unless `--i-know` is given.

`--json` prints machine-readable output; `-v` logs each ssh command to
stderr. Exit status is non-zero on any failure.

## LAN IPv6 fallback

The LAN gets IPv6 by relaying from the AIS uplink (`wan6`). The backup
uplinks (iPhone USB tethering `eth2`, wifi repeater `wwan`) deliver no IPv6:
no RA and no DHCPv6 reply. Without a fallback the relay has nothing to pass
on, and every host loses its `2405:9800:b901:94e3::/64` address, including
`::feed:da7a`.

`lan6-fallback install` puts `lan6-fallback.sh` on the router as
`/usr/sbin/lan6-fallback`, plus a hotplug hook
`/etc/hotplug.d/iface/99-lan6-fallback`. Both are listed in
`/etc/sysupgrade.conf`. The hook runs the script on every
`ifup`/`ifdown`/`ifupdate` of wan/wan6/wwan/wwan6/tethering/tethering6:

* An uplink (`wan6`, `wwan6`, `tethering6`) is up with a global /64:
  relay mode (stock config). The prefix seen on `wan6` is recorded in
  `/etc/lan6-fallback.prefix`.
* Otherwise: `network.lan.ip6prefix=<recorded prefix>` and
  `dhcp.lan.ra=server`, `dhcpv6=disabled`, `ndp=disabled`, `ra_flags=none`.
  The router takes `<prefix>::1` on `br-lan` and announces the prefix
  with router lifetime 0. Hosts form the same SLAAC/token addresses as
  usual and reach each other on them (`::feed:da7a` included, through bam's
  NDP proxy), but get no IPv6 default route: nothing is routed off the LAN,
  so IPv6 internet fails fast and IPv4 takes over.

`install` seeds `2405:9800:b901:94e3::/64` only if no prefix is recorded;
`--prefix` overwrites the recorded one. `status` shows the mode
(`relay` or `fallback`) and the recorded prefix.

## Credentials and host key

User is `root` over ssh (dropbear, password auth). The password comes from
`ROUTER_CM_BERYL_PASSWORD` if set, otherwise from
`clan vars get amy router-cm-beryl/password` (run inside the hyperconfig
checkout; about 3 s). It is handed to `sshpass` through the environment and
never printed or written.

The router's host key is pinned on first use (`StrictHostKeyChecking=accept-new`)
in `$XDG_STATE_HOME/router-cm-beryl/known_hosts`
(`~/.local/state/router-cm-beryl/known_hosts`). Delete that file after a
router reflash.

## Limitations

* Only `firewall.rule` sections and the lan6 fallback are covered; zones,
  forwardings, redirects, wifi and the rest of DHCP are deliberately out of
  scope.
* `add` always writes IPv6, wan -> lan, destination-only ACCEPT rules with a
  single port or port range. Editing existing rules is not supported: delete
  and re-add.
* The Beryl only forwards what the upstream ZTE lets through: a rule here is
  useless without a matching `router-ais ipv6-rules add` on the ZTE.
