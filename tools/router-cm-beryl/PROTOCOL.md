# GL.iNet Beryl AX (GL-MT3000) — device facts and uci shape

Recorded on 2026-09-06 against the live device at `192.168.8.1` over ssh
(via `-J root@bam.d`). Everything below was read from the device.

## Board and firmware

```
$ ubus call system board
model       GL.iNet GL-MT3000        board_name  glinet,mt3000-snand
hostname    GL-MT3000                kernel      5.4.211
release     OpenWrt 21.02-SNAPSHOT   target      mediatek/mt7981
$ cat /etc/glversion
4.8.1
```

Packages: `firewall 2021-03-23-61db17ed-1.2` (**fw3**, iptables 1.8.7; there
is no `/sbin/fw4`, no nftables), `uci 2021-04-14-4b3db117-5`,
`dropbear 2024.86-1` with `PasswordAuth on` (so ssh password auth as `root`
works; no key is installed). The GL.iNet JSON-RPC (`/rpc`) is therefore not
used.

## Transport

```
sshpass -e ssh -o StrictHostKeyChecking=accept-new \
   -o UserKnownHostsFile=$XDG_STATE_HOME/router-cm-beryl/known_hosts \
   -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
   [-J root@bam.d] root@192.168.8.1 '<command>'
```

`SSHPASS` carries the password. `-J` is plain ProxyJump: the jump hop uses
the caller's normal ssh config and keys, only the final hop gets the options
above. The router's ED25519 host key is pinned on first contact.

Reads use `ubus call uci get '{"config":"firewall","type":"rule"}'` which
returns every rule section as JSON keyed by section id, with `.anonymous`,
`.index` (position among all firewall sections) and the options as strings
(lists such as `dest_port='22 80'` come back as a single string). Anonymous
sections have ids like `cfg2692bd`; `uci -X show firewall` prints those same
ids where plain `uci show` prints `@rule[N]`. `uci get/set/delete` accept the
`cfg...` id directly.

## Firewall layout

Zones (`uci show firewall | grep zone`):

| zone     | networks           | input  | output | forward | notes           |
|----------|--------------------|--------|--------|---------|-----------------|
| lan      | lan                | ACCEPT | ACCEPT | ACCEPT  |                 |
| wan      | wan, wan6, wwan    | DROP   | ACCEPT | REJECT  | masq, mtu_fix   |
| guest    | guest              | REJECT | ACCEPT | REJECT  |                 |
| zerotier | zerotier           | ACCEPT | ACCEPT | REJECT  | masq, mtu_fix   |

Defaults: input/output ACCEPT, forward REJECT, syn_flood. Forwardings:
lan->wan, guest->wan, zerotier<->lan. Includes: `/etc/firewall.user`,
`/etc/firewall.nat6`, `/etc/firewall.dns_order`, `/usr/bin/rtp2.sh`
(reload=0), `/usr/bin/gl_block.sh`, `/etc/firewall.security` (reload=0).

IPv6 comes in on `wan6` (`proto dhcpv6` on `@wan`, i.e. `eth0`) and is
*relayed*, not routed: `dhcp.lan.{ra,dhcpv6,ndp}=relay`,
`dhcp.wan6.{ra,dhcpv6,ndp}=relay` with `master=1`. odhcpd installs
`/128` host routes for every LAN host on `br-lan` (e.g.
`2405:9800:b901:94e3::feed:50e dev br-lan proto static`) and
`2405:9800:b901:94e3::/64 dev eth0`. Forwarded packets to LAN hosts still
traverse `zone_wan_forward`, whose tail is `-j zone_wan_dest_REJECT` — that
REJECT is the TCP RST seen from the internet for unlisted addresses.
`Allow-ICMPv6-Forward` (`dest='*'`) already lets echo-request/reply through,
which is why ping works without any extra rule.

Stock rules with `src=wan` (what `ipv6-rules list` shows besides ours):
`wan_drop_leaked_dns` (disabled), `Allow-DHCPv6`, `Allow-MLD`,
`Allow-ICMPv6-Input`, `Allow-ICMPv6-Forward`, `Allow-IPSec-ESP`,
`Allow-ISAKMP`, `sambasharewan`/`glnas_ser`/`webdav_wan` (DROP).
No `redirect` sections exist.

## Pre-existing feed:da7a rule (do not touch)

Anonymous section `cfg2692bd` (`@rule[22]`, last section of the file,
`/etc/config/firewall` mtime Sep 3 09:49):

```
config rule
	option name 'Allow-inference-v6'
	option src 'wan'
	option dest 'lan'
	option family 'ipv6'
	option proto 'tcp'
	option dest_ip '2405:9800:b901:94e3::feed:da7a'
	option target 'ACCEPT'
	option dest_port '22 80 443 30000'
```

Rendered by fw3 as four `zone_wan_forward` entries
(`-d .../128 -p tcp --dport N -j zone_lan_dest_ACCEPT`). The tool's delete
guard matches any rule whose `dest_ip` covers that address.

## Rule shape written by `ipv6-rules add`

```
id=$(uci add firewall rule)
uci set firewall.$id.name='som'
uci set firewall.$id.src='wan'
uci set firewall.$id.dest='lan'
uci set firewall.$id.family='ipv6'
uci set firewall.$id.proto='all'          # or tcp|udp|tcpudp
uci set firewall.$id.dest_ip='2405:9800:b901:94e3::feed:50e'
uci set firewall.$id.target='ACCEPT'
[uci set firewall.$id.dest_port='22']     # only with --port; N or N-M
uci commit firewall
/etc/init.d/firewall reload               # == fw3 reload
```

`proto='all'` is written explicitly because fw3 treats a missing `proto` as
`tcp udp`. Resulting iptables entry:

```
-A zone_wan_forward -d 2405:9800:b901:94e3::feed:50e/128 -m comment --comment "!fw3: som" -j zone_lan_dest_ACCEPT
```

Delete: `uci delete firewall.<id>; uci commit firewall; /etc/init.d/firewall reload`.
Any failure between `uci add` and `commit` reverts with `uci revert firewall`.

## Reload behaviour

`fw3 reload` rebuilds the iptables chains in place; conntrack is not flushed.
Measured on 2026-09-06 with a TCP connect to `feed:da7a:22` from outside
immediately before and after each reload (three reloads: add test rule,
delete it, add `som`): open every time, no observable interruption. The
includes with `reload='0'` (`rtp2.sh`, `firewall.security`) are not re-run on
reload.

## Quirks

* GL firmware writes its own sections (`glnas_ser`, `webdav_wan`, ...) and
  may re-run `gl_block.sh`/`firewall.dns_order` on reload; ours survive that.
* `uci show` numbering (`@rule[N]`) shifts when sections are added or
  removed; always address rules by `cfg...` id or name.
* Ping to an exposed host from the internet depends on the *ZTE* rule for
  that address: a tcp-only ZTE rule blocks ICMPv6 upstream of the Beryl.
