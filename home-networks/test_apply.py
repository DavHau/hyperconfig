"""Unit tests for ./apply.py's uci planning (no router, no ssh).

Run: python3 -m unittest home-networks/test_apply.py (or the flake check
`site-routers-apply-tests`). The fixture is the home router's config as
read on 2026-11-14 (GL 4.11, `uci -X show`), trimmed, keys replaced.
"""

import os
import shlex
import sys
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import apply  # noqa: E402

FIXTURE = {
    "firewall": """
firewall.cfg01e63d=defaults
firewall.cfg01e63d.forward='REJECT'
firewall.cfg02dc81=zone
firewall.cfg02dc81.name='lan'
firewall.cfg02dc81.network='lan'
firewall.cfg02dc81.input='ACCEPT'
firewall.cfg02dc81.output='ACCEPT'
firewall.cfg02dc81.forward='ACCEPT'
firewall.cfg03dc81=zone
firewall.cfg03dc81.name='wan'
firewall.cfg03dc81.network='wan' 'wan6' 'wwan' 'tethering'
firewall.cfg03dc81.input='DROP'
firewall.cfg04ad58=forwarding
firewall.cfg04ad58.src='lan'
firewall.cfg04ad58.dest='wan'
firewall.cfg0592bd=rule
firewall.cfg0592bd.name='Allow-ICMPv6-Forward'
firewall.cfg0592bd.src='wan'
firewall.cfg0592bd.dest='*'
firewall.cfg10dc81=zone
firewall.cfg10dc81.name='guest'
firewall.cfg10dc81.network='guest'
firewall.cfg11ad58=forwarding
firewall.cfg11ad58.src='guest'
firewall.cfg11ad58.dest='wan'
firewall.cfg1292bd=rule
firewall.cfg1292bd.name='Allow-DHCP'
firewall.cfg1292bd.src='guest'
firewall.cfg1292bd.proto='udp'
firewall.cfg1292bd.dest_port='67-68'
firewall.cfg1292bd.target='ACCEPT'
firewall.zerotier=zone
firewall.zerotier.name='zerotier'
firewall.zerotier_lan=forwarding
firewall.zerotier_lan.src='zerotier'
firewall.zerotier_lan.dest='lan'
firewall.cfg30dc81=zone
firewall.cfg30dc81.name='iot'
firewall.cfg30dc81.network='iot'
firewall.cfg30dc81.forward='REJECT'
firewall.cfg30dc81.output='ACCEPT'
firewall.cfg30dc81.input='REJECT'
firewall.cfg31ad58=forwarding
firewall.cfg31ad58.src='iot'
firewall.cfg31ad58.dest='wan'
firewall.cfg31ad58.enabled='1'
firewall.cfg3292bd=rule
firewall.cfg3292bd.name='Allow-DHCP'
firewall.cfg3292bd.src='iot'
firewall.cfg3292bd.target='ACCEPT'
firewall.cfg3292bd.proto='udp'
firewall.cfg3292bd.dest_port='67-68'
firewall.cfg3392bd=rule
firewall.cfg3392bd.name='Allow-DNS'
firewall.cfg3392bd.src='iot'
firewall.cfg3392bd.target='ACCEPT'
firewall.cfg3392bd.proto='tcp udp'
firewall.cfg3392bd.dest_port='53'
firewall.cfg3592bd=rule
firewall.cfg3592bd.name='Block-LAN-mgmt-iot'
firewall.cfg3592bd.src='lan'
firewall.cfg3592bd.dest_ip='192.168.10.1'
firewall.cfg3592bd.proto='tcp udp'
firewall.cfg3592bd.dest_port='80 443 8080 8443'
firewall.cfg3592bd.target='REJECT'
firewall.zteu=zone
firewall.zteu.name='zteu'
firewall.zteu.device='ztxwywyczu'
firewall.zteu.input='ACCEPT'
firewall.zteu.output='ACCEPT'
firewall.zteu.forward='REJECT'
firewall.zteu.masq='1'
firewall.zteu.mtu_fix='1'
firewall.zteu_lan=forwarding
firewall.zteu_lan.src='zteu'
firewall.zteu_lan.dest='lan'
firewall.lan_zteu=forwarding
firewall.lan_zteu.src='lan'
firewall.lan_zteu.dest='zteu'
""",
    "network": """
network.lan=interface
network.lan.device='br-lan'
network.lan.ipaddr='192.168.8.1'
network.iot=interface
network.iot.force_link='1'
network.iot.device='br-iot'
network.iot.proto='static'
network.iot.ipaddr='192.168.10.1'
network.iot.netmask='255.255.255.0'
network.iot.delegate='0'
network.iot.isolate='1'
network.iot.disabled='1'
network.iot.vlan_id='10'
""",
    "wireless": """
wireless.wifi2g=wifi-iface
wireless.wifi2g.device='mt798111'
wireless.wifi2g.network='lan'
wireless.wifi2g.ifname='ra0'
wireless.wifi2g.ssid='7-Eleven'
wireless.wifi2g.key='lan-secret'
wireless.wifi2g.encryption='sae-mixed'
wireless.wifi5g=wifi-iface
wireless.wifi5g.device='mt798112'
wireless.wifi5g.network='lan'
wireless.wifi5g.ssid='7-Eleven'
wireless.wifi5g.encryption='sae-mixed'
wireless.iot2g=wifi-iface
wireless.iot2g.device='mt798111'
wireless.iot2g.network='iot'
wireless.iot2g.mode='ap'
wireless.iot2g.ifname='ra2'
wireless.iot2g.encryption='psk2'
wireless.iot2g.key='gl-default'
wireless.iot2g.ssid='GL-MT3000-25c-IoT'
wireless.iot2g.disabled='1'
wireless.iot2g.isolate='1'
wireless.iot2g.hidden='0'
wireless.iot2g.macaddr='9A:71:5D:40:60:99'
wireless.iot5g=wifi-iface
wireless.iot5g.device='mt798112'
wireless.iot5g.network='iot'
wireless.iot5g.ifname='rax2'
wireless.iot5g.disabled='1'
""",
    "dhcp": """
dhcp.lan=dhcp
dhcp.lan.interface='lan'
dhcp.cfg08fe63=host
dhcp.cfg08fe63.mac='D8:BC:38:58:E7:C0'
dhcp.cfg08fe63.ip='192.168.8.10'
dhcp.iot=dhcp
dhcp.iot.interface='iot'
dhcp.iot.start='100'
dhcp.iot.limit='150'
dhcp.iot.leasetime='12h'
dhcp.iot.dhcpv6='disabled'
dhcp.iot.ra='disabled'
dhcp.iot.ndp='disabled'
dhcp.iot.force='1'
""",
    "route_policy": """
route_policy.global=policy
route_policy.global.mode='0'
route_policy.global.append_source_if='iot'
route_policy.global.enabled='0'
""",
}

# As read live on 2026-11-14 (`iwinfo`, `grep -H . /sys/class/net/*/flags`):
# on this MTK firmware down slots show an ESSID too (ra1 "HT_AP1", rax1
# "HT_AP4", flags 0x1002 = no IFF_UP), ra2 (iot, disabled) 'unknown'.
IWINFO = """apcli0    ESSID: unknown
          Mode: Client  Channel: 1 (2.412 GHz) HT Mode: HE20
ra0       ESSID: "7-Eleven"
          Mode: Master  Channel: 1 (2.412 GHz) HT Mode: HE20
ra1       ESSID: "HT_AP1"
          Mode: Master  Channel: 1 (2.412 GHz) HT Mode: HE20
ra2       ESSID: unknown
          Mode: Master  Channel: 1 (2.412 GHz) HT Mode: HE20
rax0      ESSID: "7-Eleven"
          Mode: Master  Channel: 40 (5.200 GHz) HT Mode: HE80
rax1      ESSID: "HT_AP4"
          Mode: Master  Channel: 40 (5.200 GHz) HT Mode: HE80
"""
FLAGS = {"apcli0": "0x1003", "br-lan": "0x1203", "ra0": "0x1303", "ra1": "0x1002", "ra2": "0x1002",
         "rax0": "0x1303", "rax1": "0x1002"}


# Bridge ports as listed live (ls -d /sys/class/net/*/brport): ra0 and
# rax0 in br-lan; ra2 joins br-iot once the iot AP is up.
BRPORTS = ("eth1", "ra0", "rax0")


def wifi_out(iwinfo=IWINFO, brports=BRPORTS, **flags):
    f = {i: v for i, v in dict(FLAGS, **flags).items() if v is not None}
    return (iwinfo + "--- flags ---\n" + "".join(f"/sys/class/net/{i}/flags:{v}\n" for i, v in f.items())
            + "--- brport ---\n" + "".join(f"/sys/class/net/{i}/brport\n" for i in brports))


IWINFO_BEFORE = wifi_out()
# After the change: ra2 up with the iot SSID.
IWINFO_AFTER_IW = IWINFO.replace('ra2       ESSID: unknown', 'ra2       ESSID: "Macro"')
AFTER_BRPORTS = (*BRPORTS, "ra2")
IWINFO_AFTER = wifi_out(IWINFO_AFTER_IW, AFTER_BRPORTS, ra2="0x1303")
# 7-Eleven's 2.4 GHz did not come back after `wifi reload`, though
# iwinfo still shows its ESSID (the link is down).
IWINFO_BROKEN = wifi_out(IWINFO_AFTER_IW, AFTER_BRPORTS, ra2="0x1303", ra0="0x1002")
# ra0 up with its SSID but no longer in br-lan: serves nobody.
IWINFO_RA0_UNBRIDGED = wifi_out(IWINFO_AFTER_IW, ("eth1", "rax0", "ra2"), ra2="0x1303")
# Down slots show other ESSIDs after the reload: must not matter.
IWINFO_DOWN_SLOTS_CHANGED = wifi_out(
    IWINFO_AFTER_IW.replace('"HT_AP1"', '"HT_AP2"').replace('rax1      ESSID: "HT_AP4"', 'rax1      ESSID: unknown'),
    AFTER_BRPORTS, ra2="0x1303",
)
# rax0 gone from iwinfo and /sys after the reload.
IWINFO_RAX0_MISSING = wifi_out(
    IWINFO_AFTER_IW.replace('rax0      ESSID: "7-Eleven"\n          Mode: Master  Channel: 40 (5.200 GHz) HT Mode: HE80\n', ""),
    ("eth1", "ra0", "ra2"), ra2="0x1303", rax0=None,
)

IOT = {
    "prefix": "192.168.18.0/24",
    "address": "192.168.18.1",
    "netmask": "255.255.255.0",
    "wifiIface": "iot2g",
    "offIfaces": ["iot5g"],
    "ssid": "Macro",
    "encryption": "psk2+ccmp",
    "pskVar": "router-cm-beryl-iot/psk",
    "hosts": {"printer": {"ip": "192.168.18.20", "mac": None}},
    "reservedPrefixes": ["10.194.0.0/24", "192.168.8.0/24", "192.168.10.0/24", "192.168.20.0/24"],
}

STATE = {"name": "cm-beryl", "masqueradeFromLan": True, "masqueradeToLan": [], "iot": IOT}
PSK = apply.Secret(apply.IOT_PSK_ENV, "correct-horse-battery", "test")


class FakeUci:
    """Minimal uci: `uci -q -X show <c>`, set/delete/add_list/commit."""

    def __init__(self, texts):
        self.configs = {c: apply_text(t) for c, t in texts.items()}
        self.commands = []
        self.stdin = []

    def show(self, config):
        lines = []
        for name, s in self.configs.get(config, {}).items():
            lines.append(f"{config}.{name}={s['.type']}")
            for opt, vals in s.items():
                if opt != ".type":
                    lines.append(f"{config}.{name}.{opt}=" + " ".join(shlex.quote(v) for v in vals))
        return "\n".join(lines)

    def exec(self, cmd, env):
        for k, v in env.items():
            cmd = cmd.replace(f'"${k}"', shlex.quote(v))
        argv = shlex.split(cmd)
        assert argv[0] == "uci", cmd
        op, rest = argv[1], argv[2:]
        if op == "commit":
            return
        path, _, value = rest[0].partition("=")
        parts = path.split(".")
        conf = self.configs.setdefault(parts[0], {})
        if op == "delete":
            if len(parts) == 2:
                del conf[parts[1]]
            else:
                del conf[parts[1]][parts[2]]
        elif op == "set" and len(parts) == 2:
            conf[parts[1]] = {".type": value}
        elif op == "set":
            conf[parts[1]][parts[2]] = [value]
        elif op == "add_list":
            conf[parts[1]].setdefault(parts[2], []).append(value)
        else:
            raise AssertionError(cmd)


def apply_text(text):
    out = {}
    for line in text.strip().splitlines():
        key, _, raw = line.partition("=")
        parts = key.split(".")
        vals = shlex.split(raw)
        if len(parts) == 2:
            out[parts[1]] = {".type": vals[0]}
        else:
            out[parts[1]][parts[2]] = vals
    return out


class Result:
    def __init__(self, stdout="", returncode=0):
        self.stdout, self.returncode, self.stderr = stdout, returncode, ""


class FakeRouter:
    name = "cm-beryl"

    def __init__(self, uci, iwinfo=(IWINFO_BEFORE, IWINFO_AFTER)):
        self.uci = uci
        self.runs = []
        self.state = STATE
        # iwinfo before the change, then after it (the last one repeats).
        self.iwinfo = list(iwinfo)

    def run(self, command, check=True, timeout=120, secrets=()):
        self.runs.append((command, [s.env for s in secrets]))
        if command.startswith("iwinfo"):
            self.probes = getattr(self, "probes", 0) + 1
            out = self.iwinfo.pop(0) if len(self.iwinfo) > 1 else self.iwinfo[0]
            return Result(out)
        if command.startswith("uci -q -X show "):
            return Result(self.uci.show(command.split()[-1]))
        if " && " in command and command.startswith("uci "):
            env = {s.env: s.value for s in secrets}
            for c in command.split(" && "):
                self.uci.exec(c, env)
            return Result()
        return Result()


def plan(uci, psk=PSK, **kw):
    router = FakeRouter(uci, **kw)
    have = {c: apply.uci_show(router, c) for c in ("firewall", "network", "wireless", "dhcp", "route_policy")}
    wants = {"firewall": apply.desired_firewall(STATE, "ztxwywyczu", have["firewall"])}
    for c, s in apply.desired_iot(IOT, have, psk).items():
        wants.setdefault(c, {}).update(s)
    return router, wants


class SectionCommands(unittest.TestCase):
    def test_exact_deletes_extra_options(self):
        cmds = apply.section_commands("f", "s", ("rule", {"a": "1"}), {".type": "rule", "a": ["1"], "b": ["2"]})
        self.assertEqual(cmds, ["uci delete f.s.b"])

    def test_adopt_keeps_extra_options(self):
        cmds = apply.section_commands("f", "s", ("rule", {"a": "1"}, False), {".type": "rule", "a": ["0"], "b": ["2"]})
        self.assertEqual(cmds, ["uci set f.s.a=1"])

    def test_none_option_deleted_only_if_there(self):
        self.assertEqual(apply.section_commands("f", "s", ("r", {"x": None}, False), {".type": "r"}), [])
        self.assertEqual(
            apply.section_commands("f", "s", ("r", {"x": None}, False), {".type": "r", "x": ["1"]}),
            ["uci delete f.s.x"],
        )

    def test_secret_never_literal(self):
        cmds = apply.section_commands("w", "i", ("wifi-iface", {"key": PSK}, False), {".type": "wifi-iface", "key": ["old"]})
        self.assertEqual(cmds, ['uci set w.i.key="$IOT_PSK"'])
        self.assertNotIn(PSK.value, " ".join(cmds))
        same = {".type": "wifi-iface", "key": [PSK.value]}
        self.assertEqual(apply.section_commands("w", "i", ("wifi-iface", {"key": PSK}, False), same), [])
        unknown = apply.Secret(apply.IOT_PSK_ENV, None, "test")
        self.assertEqual(len(apply.section_commands("w", "i", ("wifi-iface", {"key": unknown}, False), same)), 1)


class CheckIot(unittest.TestCase):
    def test_declared_block_is_valid(self):
        apply.check_iot(IOT)

    def test_gl_default_prefix_collides_with_playa(self):
        bad = dict(IOT, prefix="192.168.10.0/24", address="192.168.10.1",
                   hosts={"printer": {"ip": "192.168.10.20", "mac": None}})
        with self.assertRaisesRegex(apply.Failed, "overlaps 192.168.10.0/24"):
            apply.check_iot(bad)

    def test_bad_mac_and_outside_ip(self):
        with self.assertRaisesRegex(apply.Failed, "mac"):
            apply.check_iot(dict(IOT, hosts={"p": {"ip": "192.168.18.20", "mac": "aa:bb"}}))
        with self.assertRaisesRegex(apply.Failed, "outside"):
            apply.check_iot(dict(IOT, hosts={"p": {"ip": "192.168.8.20", "mac": None}}))

    # `ip -4 route` as read live on 2026-11-14.
    ROUTES = """default via 192.168.1.1 dev eth0 proto static src 192.168.1.102 metric 10
default via 192.168.0.1 dev eth2 proto static src 192.168.0.169 metric 30
10.194.0.0/24 dev ztxwywyczu proto kernel scope link src 10.194.0.4
192.168.0.0/24 dev eth2 proto static scope link metric 30
192.168.1.0/24 dev eth0 proto static scope link metric 10
192.168.8.0/24 dev br-lan proto kernel scope link src 192.168.8.1
192.168.10.0/24 via 10.194.0.10 dev ztxwywyczu proto static metric 5000
192.168.20.0/24 via 10.194.0.20 dev ztxwywyczu proto static metric 5000
192.168.194.0/24 dev zt44xbwxfb proto kernel scope link src 192.168.194.4
"""

    def test_live_routes_ok(self):
        apply.check_iot_routes(IOT, self.ROUTES, "br-iot")
        # Our own route from an earlier run is fine.
        apply.check_iot_routes(IOT, self.ROUTES + "192.168.18.0/24 dev br-iot proto kernel scope link src 192.168.18.1\n",
                               "br-iot")

    # `ip -4 route show table all` additions as read live on 2026-11-14:
    # table local (own addresses, broadcasts); GL's policy tables
    # (8000, 16800) were empty then.
    LOCAL = """broadcast 192.168.8.0 dev br-lan table local proto kernel scope link src 192.168.8.1
local 192.168.8.1 dev br-lan table local proto kernel scope host src 192.168.8.1
broadcast 192.168.8.255 dev br-lan table local proto kernel scope link src 192.168.8.1
local 127.0.0.0/8 dev lo table local proto kernel scope host src 127.0.0.1
"""
    OWN_IOT = """192.168.18.0/24 dev br-iot proto kernel scope link src 192.168.18.1
broadcast 192.168.18.0 dev br-iot table local proto kernel scope link src 192.168.18.1
local 192.168.18.1 dev br-iot table local proto kernel scope host src 192.168.18.1
broadcast 192.168.18.255 dev br-iot table local proto kernel scope link src 192.168.18.1
"""

    def test_all_tables_live_and_own_local_entries_ok(self):
        apply.check_iot_routes(IOT, self.ROUTES + self.LOCAL, "br-iot")
        apply.check_iot_routes(IOT, self.ROUTES + self.LOCAL + self.OWN_IOT, "br-iot")

    def test_policy_table_and_foreign_local_entries_collide(self):
        for extra in ("192.168.16.0/21 dev wgclient table 8000 proto static scope link\n",
                      "192.168.18.0/24 via 10.0.0.1 dev tun0 table 16800\n",
                      "local 192.168.18.7 dev eth0 table local proto kernel scope host src 192.168.18.7\n",
                      "broadcast 192.168.18.255 dev eth0 table local proto kernel scope link src 192.168.18.7\n"):
            with self.subTest(extra=extra), self.assertRaisesRegex(apply.Failed, "overlaps the router's route"):
                apply.check_iot_routes(IOT, self.ROUTES + self.LOCAL + extra, "br-iot")

    def test_apply_reads_every_table(self):
        router = FakeRouter(FakeUci(FIXTURE))
        state = dict(STATE, address="192.0.2.1", networkId="n", ztIpv4="10.194.0.4", ztIpv6="fd00::4")
        seen = []
        with mock.patch.object(apply, "Router", return_value=router), \
                mock.patch.object(router, "connect", create=True), \
                mock.patch.object(apply, "check_pending"), mock.patch.object(apply, "ensure_keys", return_value=[]), \
                mock.patch.object(apply, "ensure_join", return_value=[]), \
                mock.patch.object(apply, "networks", return_value={"n": {}}), \
                mock.patch.object(apply, "wait_network", return_value={"portDeviceName": "ztxwywyczu"}), \
                mock.patch.object(apply, "iot_psk", return_value=PSK), \
                mock.patch.object(apply, "check_iot_routes", side_effect=lambda i, r, d: seen.append(d)), \
                mock.patch("sys.stderr"):
            apply.apply(state, True, 300, lambda m: None)
        self.assertIn("ip -4 route show table all", [c for c, _ in router.runs])
        self.assertEqual(len(seen), 1)

    def test_wan_dhcp_prefix_moved_onto_iot(self):
        moved = self.ROUTES.replace("192.168.0.0/24 dev eth2", "192.168.16.0/21 dev eth2")
        with self.assertRaisesRegex(apply.Failed, "overlaps the router's route `192.168.16.0/21 dev eth2"):
            apply.check_iot_routes(IOT, moved, "br-iot")
        with self.assertRaisesRegex(apply.Failed, "overlaps"):
            apply.check_iot_routes(IOT, self.ROUTES + "unreachable 192.168.18.0/24\n", "br-iot")
        with self.assertRaisesRegex(apply.Failed, "overlaps"):
            apply.check_iot_routes(IOT, self.ROUTES + "192.168.18.0/24 dev eth0 scope link\n", "br-iot")


class DesiredIot(unittest.TestCase):
    def setUp(self):
        self.uci = FakeUci(FIXTURE)
        self.router, self.wants = plan(self.uci)
        self.changes = apply.ensure_uci(self.router, self.wants, True, 300, [PSK])
        self.cmds = [c.strip() for c in self.changes if c.startswith("    ")]

    def test_iot_to_wan_forwarding_deleted(self):
        self.assertIn("uci delete firewall.cfg31ad58", self.cmds)

    def test_lan_to_iot_added_no_iot_to_anything(self):
        self.assertIn("uci set firewall.lan_iot=forwarding", self.cmds)
        self.assertIn("uci set firewall.lan_iot.src=lan", self.cmds)
        self.assertIn("uci set firewall.lan_iot.dest=iot", self.cmds)
        self.assertFalse([c for c in self.cmds if "src=iot" in c and "forwarding" in c])

    def test_lan_wifi_zteu_and_lan_untouched(self):
        for c in self.cmds:
            self.assertNotRegex(c, r"wireless\.wifi[25]g|network\.lan\b|dhcp\.lan\b|firewall\.zteu|firewall\.cfg0[2-5]")

    def test_wifi_2g_only_wpa2_no_pmf(self):
        self.assertIn("uci set wireless.iot2g.disabled=0", self.cmds)
        self.assertIn("uci set wireless.iot2g.encryption=psk2+ccmp", self.cmds)
        self.assertIn("uci set wireless.iot2g.ieee80211w=0", self.cmds)
        self.assertIn('uci set wireless.iot2g.key="$IOT_PSK"', self.cmds)
        self.assertFalse([c for c in self.cmds if c.startswith("uci set wireless.iot5g")])

    def test_printer_name_without_mac_no_lease(self):
        self.assertIn("uci set dhcp.iot_host_printer=domain", self.cmds)
        self.assertFalse([c for c in self.cmds if "iot_lease_" in c])

    def test_dry_run_runs_no_change(self):
        self.assertEqual([c for c, _ in self.router.runs if not c.startswith("uci -q -X show")], [])

    def test_apply_then_second_run_is_noop(self):
        router, wants = plan(self.uci)
        with mock.patch.object(apply, "arm"), mock.patch.object(apply, "disarm", return_value=True), \
                mock.patch.object(apply.time, "sleep"), mock.patch("sys.stderr"):
            apply.ensure_uci(router, wants, False, 300, [PSK])
        change = [(c, s) for c, s in router.runs if c.startswith("uci ") and " && " in c][0]
        self.assertNotIn(PSK.value, change[0])
        self.assertEqual(change[1], ["IOT_PSK"])
        self.assertIn("/etc/init.d/network reload", [c.split(" >")[0] for c, _ in router.runs])
        self.assertEqual(self.uci.configs["wireless"]["iot2g"]["key"], [PSK.value])
        self.assertEqual(self.uci.configs["wireless"]["iot2g"]["macaddr"], ["9A:71:5D:40:60:99"])
        self.assertEqual(self.uci.configs["wireless"]["wifi2g"]["key"], ["lan-secret"])
        router2, wants2 = plan(self.uci)
        self.assertEqual(apply.ensure_uci(router2, wants2, True, 300, [PSK]), [])

    def test_no_dns_for_iot(self):
        # GL's Allow-DNS rule goes, no rule of ours replaces it.
        self.assertIn("uci delete firewall.cfg3392bd", self.cmds)
        self.assertFalse([c for c in self.cmds if "dest_port=53" in c])
        # The lease names no DNS server.
        self.assertIn("uci add_list dhcp.iot.dhcp_option=6", self.cmds)

    def test_iot_out_of_gl_route_policy(self):
        self.assertIn("uci delete route_policy.global.append_source_if", self.cmds)
        uci = FakeUci(dict(FIXTURE, route_policy=FIXTURE["route_policy"].replace("'iot'", "'iot' 'guest'")))
        _, wants = plan(uci)
        self.assertEqual(wants["route_policy"]["global"][1], {"append_source_if": ["guest"]})
        _, wants = plan(FakeUci({c: t for c, t in FIXTURE.items() if c != "route_policy"}))
        self.assertNotIn("route_policy", wants)

    def test_iot_out_of_dns_dispatcher(self):
        # Load-bearing for "no DNS": GL's /etc/firewall.dns_order adds the
        # L3 device of every interface in 'ovpnserver wgserver lan guest' +
        # append_source_if to its DNS dispatcher; with force_dns=1 port 53
        # from it is REDIRECTed to dnsmasq, and fw3's DNAT accept lets that
        # past the iot zone's input REJECT. After the change iot must not
        # be in that list, and GL re-adding it shows as a change.
        router, wants = plan(self.uci)
        with mock.patch.object(apply, "arm"), mock.patch.object(apply, "disarm", return_value=True), \
                mock.patch.object(apply.time, "sleep"), mock.patch("sys.stderr"):
            apply.ensure_uci(router, wants, False, 300, [PSK])
        rp = self.uci.configs["route_policy"]["global"]
        dns_sources = ["ovpnserver", "wgserver", "lan", "guest", *rp.get("append_source_if", [])]
        self.assertNotIn("iot", dns_sources)
        self.uci.configs["route_policy"]["global"]["append_source_if"] = ["iot"]
        router2, wants2 = plan(self.uci)
        self.assertIn("route_policy.global: set", apply.ensure_uci(router2, wants2, True, 300, [PSK]))

    def _apply(self, router, wants, revert_after=300):
        armed, disarmed = [], []
        with mock.patch.object(apply, "arm", side_effect=lambda r, s, rl: armed.append(s)), \
                mock.patch.object(apply, "disarm", side_effect=lambda r: disarmed.append(1) or True), \
                mock.patch.object(apply.time, "sleep"), mock.patch("sys.stderr"):
            try:
                apply.ensure_uci(router, wants, False, revert_after, [PSK])
                return armed, disarmed, None
            except apply.Failed as e:
                return armed, disarmed, e

    def test_wifi_change_gets_600s_revert(self):
        router, wants = plan(self.uci)
        armed, disarmed, err = self._apply(router, wants)
        self.assertIsNone(err)
        self.assertEqual(armed, [600])
        self.assertEqual(disarmed, [1])
        # One probe before, two consecutive good ones after the reload.
        self.assertEqual(router.probes, 3)

    def test_settle_covers_gl_wifi_config_wait(self):
        # GL's mtk.sh waits up to 90 s for /tmp/wait_for_wifi_config.
        self.assertGreaterEqual(apply.WIFI_SETTLE, 120)
        # ...and the 600 s revert still leaves room for the reloads.
        self.assertLessEqual(2 * apply.WIFI_SETTLE, apply.SLOW_REVERT_AFTER - 300)

    def test_one_good_probe_then_bad_is_not_healthy(self):
        # A good probe right after the reload, then ra0 drops: a blip.
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_AFTER, IWINFO_BROKEN))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))):
            _, disarmed, err = self._apply(router, wants)
        self.assertEqual(disarmed, [])
        self.assertRegex(str(err), r"down since the change: ra0 \(7-Eleven\)")

    def test_good_bad_good_good_needs_two_in_a_row(self):
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_AFTER, IWINFO_BROKEN, IWINFO_AFTER))
        _, disarmed, err = self._apply(router, wants)
        self.assertIsNone(err)
        self.assertEqual(disarmed, [1])
        self.assertEqual(router.probes, 5)

    def test_failed_probe_resets_the_good_count(self):
        # good, iwinfo failure, good, good: the failure must reset.
        router, wants = plan(self.uci)
        outs = iter([IWINFO_BEFORE, IWINFO_AFTER, None, IWINFO_AFTER, IWINFO_AFTER])
        n = []

        def up(r):
            n.append(1)
            o = next(outs)
            return None if o is None else apply.parse_wifi_up(o)
        with mock.patch.object(apply, "wifi_up", side_effect=up):
            _, disarmed, err = self._apply(router, wants)
        self.assertIsNone(err)
        self.assertEqual(len(n), 5)

    def test_up_ap_without_brport_counts_as_down(self):
        self.assertNotIn("ra0", apply.parse_wifi_up(IWINFO_RA0_UNBRIDGED))
        self.assertIn("rax0", apply.parse_wifi_up(IWINFO_RA0_UNBRIDGED))
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_RA0_UNBRIDGED))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))):
            _, disarmed, err = self._apply(router, wants)
        self.assertEqual(disarmed, [])
        self.assertRegex(str(err), r"down since the change: ra0 \(7-Eleven\)")

    def test_probe_lists_bridge_ports(self):
        router = FakeRouter(self.uci)
        apply.wifi_up(router)
        self.assertIn("/sys/class/net/*/brport", router.runs[0][0])
        self.assertIn(apply.BRPORT_MARK, router.runs[0][0])

    def test_arm_clears_a_stale_pidfile_first(self):
        # busybox start-stop-daemon matches -x /bin/sh against the busybox
        # binary: a stale pidfile naming any busybox process would make it
        # refuse to start the revert.
        seen = []
        router = FakeRouter(self.uci)
        with mock.patch.object(router, "run", side_effect=lambda c, **kw: seen.append(c) or Result()):
            apply.arm(router, 600, ["wifi reload"])
        cmd = seen[0]
        self.assertIn(f"rm -f {apply.PIDFILE} && start-stop-daemon -S -b -m -p {apply.PIDFILE} ", cmd)
        self.assertLess(cmd.index(f"touch {apply.ARMED}"), cmd.index(f"rm -f {apply.PIDFILE} "))

    def test_arm_with_stale_pidfile_starts_the_revert(self):
        # Run arm's command in a real sh with a fake start-stop-daemon that,
        # like busybox's, refuses while the pidfile names a live process.
        import subprocess
        import tempfile
        seen = []
        router = FakeRouter(self.uci)
        with mock.patch.object(router, "run", side_effect=lambda c, **kw: seen.append(c) or Result()):
            apply.arm(router, 600, ["wifi reload"])
        with tempfile.TemporaryDirectory() as d:
            cmd = seen[0].replace("/tmp/site-routers-apply", f"{d}/sra").replace("/etc/config/", f"{d}/etc/")
            os.makedirs(f"{d}/etc")
            os.makedirs(f"{d}/bin")
            with open(f"{d}/bin/start-stop-daemon", "w") as f:
                f.write('#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -p ] && p=$2; shift; done\n'
                        '[ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null && { echo running >&2; exit 1; }\n'
                        'echo started > "$p.started"\n')
            os.chmod(f"{d}/bin/start-stop-daemon", 0o755)
            with open(f"{d}/sra.pid", "w") as f:
                f.write(str(os.getpid()))  # a live process: stale for the revert
            r = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True,
                               env=dict(os.environ, PATH=f"{d}/bin:" + os.environ["PATH"]))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue(os.path.exists(f"{d}/sra.pid.started"))

    def test_revert_already_fired_message(self):
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_BROKEN))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))), \
                mock.patch.object(router, "run", wraps=router.run) as run:
            def fake(c, **kw):
                return Result(returncode=3) if f"{apply.REVERT}.now" in c else FakeRouter.run(router, c, **kw)
            run.side_effect = fake
            _, disarmed, err = self._apply(router, wants)
        self.assertEqual(disarmed, [])
        self.assertRegex(str(err), "the armed revert already restored")

    def test_revert_now_states(self):
        router = FakeRouter(self.uci)
        for rc, want in ((0, "now"), (3, "fired"), (1, None), (255, None)):
            with mock.patch.object(router, "run", return_value=Result(returncode=rc)):
                self.assertEqual(apply.revert_now(router), want)

    def test_lan_ssid_down_after_change_reverts_now(self):
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_BROKEN))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))):
            armed, disarmed, err = self._apply(router, wants)
        self.assertEqual(armed, [600])
        self.assertEqual(disarmed, [], "a dead 7-Eleven radio must not disarm the revert")
        self.assertRegex(str(err), r"ra0 \(7-Eleven\)")
        self.assertRegex(str(err), "reverted now")
        now = [c for c, _ in router.runs if f"{apply.REVERT}.now" in c]
        self.assertEqual(len(now), 1)
        self.assertIn("sed '2s/^sleep .*/:/'", now[0])

    def test_revert_now_sed_drops_only_the_sleep(self):
        # The armed script's line 2 is its sleep; revert_now's sed must
        # turn exactly that into a no-op.
        seen = []
        router = FakeRouter(self.uci)
        with mock.patch.object(router, "run", side_effect=lambda c, **kw: seen.append(c) or Result()):
            apply.arm(router, 600, ["wifi reload"])
        script = shlex.split(seen[0].split("printf %s ", 1)[1])[0]
        import subprocess
        out = subprocess.run(["sed", "2s/^sleep .*/:/"], input=script, capture_output=True, text=True).stdout
        self.assertEqual(script.splitlines()[1], "sleep 600")
        self.assertEqual(out.splitlines()[1], ":")
        self.assertEqual(out.splitlines()[2:], script.splitlines()[2:])

    def test_immediate_revert_failing_leaves_armed_one(self):
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_BROKEN))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))), \
                mock.patch.object(apply, "revert_now", return_value=None):
            _, disarmed, err = self._apply(router, wants)
        self.assertEqual(disarmed, [])
        self.assertRegex(str(err), r"immediate revert failed, revert left armed \(it may already have run\)")

    def test_dead_ra0_with_essid_still_shown_is_not_up(self):
        # iwinfo keeps showing "7-Eleven" on ra0 with the link down.
        self.assertNotIn("ra0", apply.parse_wifi_up(IWINFO_BROKEN))
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_BROKEN))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))):
            _, disarmed, err = self._apply(router, wants)
        self.assertEqual(disarmed, [])
        self.assertIsNotNone(err)

    def test_up_means_iff_up_master_and_essid(self):
        # Live format: ra1/rax1 show an ESSID but are down; rax0 is up
        # (operstate 'unknown' does not matter); apcli0 is a client.
        self.assertEqual(apply.parse_wifi_up(IWINFO_BEFORE), {"ra0": "7-Eleven", "rax0": "7-Eleven"})
        self.assertEqual(apply.parse_wifi_up(IWINFO_AFTER),
                         {"ra0": "7-Eleven", "ra2": "Macro", "rax0": "7-Eleven"})

    def test_down_slots_changing_essid_no_revert(self):
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_DOWN_SLOTS_CHANGED))
        _, disarmed, err = self._apply(router, wants)
        self.assertIsNone(err)
        self.assertEqual(disarmed, [1])
        self.assertFalse([c for c, _ in router.runs if f"{apply.REVERT}.now" in c])

    def test_up_interface_missing_after_reload_counts_as_gone(self):
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_RAX0_MISSING))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))):
            _, disarmed, err = self._apply(router, wants)
        self.assertEqual(disarmed, [])
        self.assertRegex(str(err), r"down since the change: rax0 \(7-Eleven\)")

    def test_wifi_probe_without_flags_is_a_failure(self):
        router = FakeRouter(self.uci, iwinfo=(IWINFO,))
        self.assertIsNone(apply.wifi_up(router))

    def test_iot_ssid_missing_keeps_revert_armed(self):
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_BEFORE))
        with mock.patch.object(apply.time, "monotonic", side_effect=iter(range(0, 10000, 30))):
            _, disarmed, err = self._apply(router, wants)
        self.assertEqual(disarmed, [])
        self.assertRegex(str(err), "not broadcast: Macro")

    def test_radio_back_within_window_disarms(self):
        # Down on the first look after the reload, back on the second.
        router, wants = plan(self.uci, iwinfo=(IWINFO_BEFORE, IWINFO_BROKEN, IWINFO_AFTER))
        _, disarmed, err = self._apply(router, wants)
        self.assertIsNone(err)
        self.assertEqual(disarmed, [1])

    def test_mac_adds_lease(self):
        iot = dict(IOT, hosts={"printer": {"ip": "192.168.18.20", "mac": "F4:A9:97:00:11:22"}})
        have = {c: apply_text(FIXTURE[c]) for c in FIXTURE}
        want = apply.desired_iot(iot, have, PSK)["dhcp"]
        self.assertEqual(
            want["iot_lease_printer"],
            ("host", {"name": "printer", "mac": "f4:a9:97:00:11:22", "ip": "192.168.18.20"}),
        )


class SecretsFailClosed(unittest.TestCase):
    def _command(self):
        router = apply.Router({"name": "r", "address": "192.0.2.1"}, lambda m: None)
        with mock.patch.object(apply.subprocess, "run", return_value=Result()) as run, \
                mock.patch.object(apply, "known_hosts", return_value="/dev/null"):
            router.run("echo ran; uci set w.i.key=\"$IOT_PSK\"", secrets=[PSK])
        return run.call_args.args[0][-1], run.call_args.kwargs["input"]

    def test_empty_or_missing_stdin_runs_nothing(self):
        command, stdin = self._command()
        self.assertNotIn(PSK.value, command)
        self.assertEqual(stdin, PSK.value + "\n")
        import subprocess
        for feed in ("", "\n"):
            r = subprocess.run(["sh", "-c", command.replace("uci set", "echo set")], input=feed,
                               capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, "")
        r = subprocess.run(["sh", "-c", command.replace("uci set", "echo set")], input=stdin,
                           capture_output=True, text=True)
        self.assertEqual(r.stdout, f"ran\nset w.i.key={PSK.value}\n")


class PendingRevertHint(unittest.TestCase):
    def test_restore_reloads_everything(self):
        router = FakeRouter(FakeUci(FIXTURE))
        router.state = dict(STATE, address="192.0.2.1")
        with mock.patch.object(router, "run", return_value=Result("live")):
            with self.assertRaises(apply.Failed) as e:
                apply.check_pending(router)
        for cmd in apply.RELOADS.values():
            self.assertIn(cmd, str(e.exception))


if __name__ == "__main__":
    unittest.main()
