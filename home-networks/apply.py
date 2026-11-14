"""site-routers-apply [--dry-run] [--revert-after SECONDS] [ROUTER ...]

Converges the site routers of ./sites.nix (default: all) to their part of
the zt-eu bridge, over ssh + uci. Idempotent: what already matches is left
alone, so a second run reports no changes and reloads nothing.

Per router, in this order:
  1. Dave's admin keys (the clan sshd instance's) in dropbear's
     authorized_keys; keys already there stay, others are added.
  2. zt-eu joined, persistently (the zerotier uci section's `join` list,
     the old network kept) and live (`zerotier-cli join`, no restart);
     then waits until zt-eu is OK with the router's pinned IPv4 (edi must
     already authorize it: deploy edi first).
  3. Firewall: zone `zteu` on the zt-eu device itself (no netifd
     interface: netifd flushes the addresses of a device it claims, and
     ZeroTier does not put them back), input/output ACCEPT, forwardings
     zteu<->lan, masquerading LAN traffic into zt-eu where the site's LAN
     is not routed (masqueradeFromLan) and zt-eu traffic into the LAN
     where the router is not the LAN's gateway (masqueradeToLan: one nat
     section `zteu_masq_<n>` per source prefix, fw4 takes one src_ip).
     Before committing, /etc/config is snapshotted and a detached revert is
     armed on the router: after --revert-after seconds (default 300, at
     least 600 when network or wireless changes) it restores the snapshot
     and reloads what was touched, unless a fresh ssh connection made
     after the reload has disarmed it. When network or wireless changed,
     every AP up before the run (IFF_UP set, iwinfo `Mode: Master` with
     an ESSID, a bridge port) must be up again with its SSID (and every
     SSID the run turns on up) in two consecutive probes within 120 s
     first; otherwise the revert is fired right
     away over ssh (the armed one stays the fallback) and the router
     fails: the router is reached over WAN/zerotier,
     so a dead LAN radio would not stop the disarm. Finally checks
     that the zt-eu addresses are on the device.
  4. The offline-devices network (`iot` in ./sites.nix), on routers that
     declare one, in the same armed change as step 3 (one snapshot, one
     revert; the revert reloads every config touched). Adopts GL's
     prepared IoT sections: network.iot renumbered and enabled, IPv4 only;
     the 2.4 GHz wifi-iface on with the declared SSID, psk2+ccmp, PMF off
     and the PSK from `clan vars get amy <pskVar>` (fed over ssh stdin,
     never on a command line or in the output), 5 GHz off; dhcp.iot on,
     no DHCPv6/RA, no DNS server in the lease (option 6 empty). Firewall:
     zone iot REJECT in/forward, input only DHCP (IPv4, no DNS); every
     other rule, redirect or forwarding naming iot deleted (GL's iot ->
     wan and Allow-DNS included), forwarding lan -> iot added; `iot`
     dropped from GL's route_policy.global.append_source_if (else GL's
     VPN client adds iot -> <vpn>, and GL's /etc/firewall.dns_order,
     with gl-dns-v2 force_dns on, redirects br-iot's port 53 to dnsmasq,
     which fw3's DNAT accept lets through past the iot input REJECT:
     this removal is load-bearing for "no DNS").
     Before planning, the prefix is checked against the router's live
     `ip -4 route show table all` too (a WAN's DHCP prefix can change).
     Hosts: a DNS name each (dhcp `domain` iot_host_<n>, so <n>.lan) and,
     once its MAC is declared, a DHCP reservation (iot_lease_<n>).
     A dry run lists the exact uci commands.

A revert still pending from an interrupted run fails the router before
anything else (it would undo this run's result, and arming again would
overwrite its snapshot); the error says how to keep or restore.

ssh is root@<address> (the old zerotier net) with your keys; a router
without them is reached with its password from `clan vars get amy
<passwordVar>` (run from the repo root) through sshpass, once: step 1 then
installs the keys. A router without a passwordVar is keys only. Host keys
are pinned in $XDG_STATE_HOME/site-routers/known_hosts. A failing router
does not stop the others; the exit status is 1 if any failed.
"""

import argparse
import ipaddress
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

ARMED = "/tmp/site-routers-apply.armed"
BACKUP = "/tmp/site-routers-apply.backup"
REVERT = "/tmp/site-routers-apply.revert"
PIDFILE = "/tmp/site-routers-apply.pid"
JOIN_TIMEOUT = 180


class Failed(Exception):
    pass


def known_hosts():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    path = Path(base) / "site-routers" / "known_hosts"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


class Router:
    def __init__(self, state, log):
        self.state = state
        self.name = state["name"]
        self.log = log
        self.password = None

    def _argv(self):
        # Every command is its own connection (no multiplexing), so each
        # one is a fresh login.
        opts = [
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={known_hosts()}",
            "-o", "ControlPath=none",
        ]
        if self.password is None:
            opts += ["-o", "BatchMode=yes"]
        else:
            opts += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
        argv = ["ssh", *opts, f"root@{self.state['address']}"]
        return ["sshpass", "-e", *argv] if self.password is not None else argv

    def run(self, command, check=True, timeout=120, secrets=()):
        """`secrets`: Secret values read from stdin into shell variables
        before `command`: never in a local argv, the log or the output."""
        self.log(f"{self.name}$ {command}")
        env = dict(os.environ, SSHPASS=self.password) if self.password is not None else None
        stdin = None
        if secrets:
            # Fail closed: no line or an empty one runs nothing (never an
            # empty key).
            reads = "".join(f'IFS= read -r {s.env} && [ -n "${s.env}" ] && ' for s in secrets)
            command = f"{reads}{{ {command}; }}"
            stdin = "".join(f"{s.value}\n" for s in secrets)
        try:
            r = subprocess.run(
                [*self._argv(), command], capture_output=True, text=True, timeout=timeout, env=env,
                input=stdin,
            )
        except subprocess.TimeoutExpired:
            raise Failed(f"ssh {self.name}: timed out: {command}") from None
        if check and r.returncode != 0:
            raise Failed(f"ssh {self.name}: exit {r.returncode}: {command}: {r.stderr.strip()}")
        return r

    def connect(self):
        r = self.run("true", check=False, timeout=60)
        if r.returncode == 0:
            return
        if "Permission denied" not in r.stderr:
            raise Failed(f"ssh {self.name}: {r.stderr.strip()}")
        var = self.state.get("passwordVar")
        if var is None:
            raise Failed(f"{self.name}: key login refused (no passwordVar): {r.stderr.strip()}")
        got = subprocess.run(["clan", "vars", "get", "amy", var], capture_output=True, text=True)
        if got.returncode != 0 or not got.stdout.strip():
            raise Failed(f"{self.name}: key login refused and no password: clan vars get amy {var}: {got.stderr.strip()}")
        self.password = got.stdout.rstrip("\n")
        print(f"{self.name}: no key login, using the password from {var}", file=sys.stderr)
        self.run("true", timeout=60)


# --- uci ---------------------------------------------------------------


def uci_show(router, config):
    """{section: {".type": type, option: [values]}} of one uci config.

    `-X`: anonymous sections by their cfg id (GL's iot zone, rules and
    forwardings are anonymous), stable within one uncommitted change.
    """
    out = router.run(f"uci -q -X show {config}", check=False).stdout
    sections = {}
    for line in out.splitlines():
        key, _, raw = line.partition("=")
        parts = key.split(".")
        values = shlex.split(raw)
        if len(parts) == 2:
            sections.setdefault(parts[1], {})[".type"] = values[0] if values else ""
        elif len(parts) == 3:
            sections.setdefault(parts[1], {})[parts[2]] = values
    return sections


class Secret:
    """An option value fed over ssh stdin as $<env>, never on a command line.

    `value` None: unknown (dry run before the var exists), always a change.
    """

    def __init__(self, env, value, source):
        self.env, self.value, self.source = env, value, source

    def __eq__(self, other):
        return isinstance(other, Secret) and (self.env, self.value) == (other.env, other.value)

    def __repr__(self):
        return f"Secret({self.env}, from {self.source})"


def section_commands(config, name, want, have):
    """uci commands turning section `name` from `have` into `want` (None = absent).

    `want` is (type, options) or (type, options, exact): exact (default)
    deletes options not in `options`; exact=False adopts a firmware
    section, keeping its other options. An option value of None means
    absent (deleted if there).
    """
    q = shlex.quote
    if want is None:
        return [f"uci delete {config}.{name}"] if have is not None else []
    stype, options, *rest = want
    exact = rest[0] if rest else True
    if have is not None and have.get(".type") != stype:
        cmds, have = [f"uci delete {config}.{name}"], None
    else:
        cmds = []
    if have is None:
        cmds.append(f"uci set {config}.{name}={stype}")
        have = {}
    if exact:
        for opt in sorted(set(have) - set(options) - {".type"}):
            cmds.append(f"uci delete {config}.{name}.{opt}")
    for opt, value in options.items():
        if value is None:
            if opt in have:
                cmds.append(f"uci delete {config}.{name}.{opt}")
            continue
        if isinstance(value, Secret):
            if value.value is None or have.get(opt) != [value.value]:
                cmds.append(f'uci set {config}.{name}.{opt}="${value.env}"')
            continue
        values = value if isinstance(value, list) else [value]
        if have.get(opt) == values:
            continue
        if isinstance(value, list):
            if opt in have:
                cmds.append(f"uci delete {config}.{name}.{opt}")
            cmds += [f"uci add_list {config}.{name}.{opt}={q(v)}" for v in values]
        else:
            cmds.append(f"uci set {config}.{name}.{opt}={q(value)}")
    return cmds


MASQ_PREFIX = "zteu_masq_"


def desired_firewall(state, device, have):
    """{section: want} for every firewall section this tool owns."""
    want = {
        "zteu": (
            "zone",
            {
                "name": "zteu",
                "device": [device],
                "input": "ACCEPT",
                "output": "ACCEPT",
                "forward": "REJECT",
                "masq": "1" if state["masqueradeFromLan"] else "0",
                "mtu_fix": "1",
            },
        ),
        "zteu_lan": ("forwarding", {"src": "zteu", "dest": "lan"}),
        "lan_zteu": ("forwarding", {"src": "lan", "dest": "zteu"}),
    }
    # Ours by name; any not wanted (fewer prefixes than before) goes.
    want.update({name: None for name in have if name.startswith(MASQ_PREFIX)})
    for i, prefix in enumerate(state["masqueradeToLan"], 1):
        # fw4: a nat rule's `src` is the zone the traffic leaves through.
        want[f"{MASQ_PREFIX}{i}"] = (
            "nat",
            {
                "name": f"zteu-to-lan-masq-{i}",
                "src": "lan",
                "family": "any",
                "proto": "all",
                "src_ip": prefix,
                "target": "MASQUERADE",
            },
        )
    return want


# --- iot (offline devices) ---------------------------------------------

IOT_PSK_ENV = "IOT_PSK"
IOT_HOST_PREFIX = "iot_host_"  # dhcp domain: name -> ip
IOT_LEASE_PREFIX = "iot_lease_"  # dhcp host: mac -> ip
# Reload commands per config, in the order they run after a commit.
RELOADS = {
    "network": "/etc/init.d/network reload",
    "wireless": "wifi reload",
    "dhcp": "/etc/init.d/dnsmasq reload",
    "firewall": "/etc/init.d/firewall reload",
    # route_policy: no reload; GL's vpn-client reads it when it starts.
}
# Configs whose reload can take a radio or a link down for a while: the
# revert then gets at least this long (the Wi-Fi check alone waits up to 120 s).
SLOW_CONFIGS = {"network", "wireless"}
SLOW_REVERT_AFTER = 600
WIFI_SETTLE = 120  # seconds the radios get to come back after `wifi reload`;
# GL's /lib/netifd/wireless/mtk.sh alone waits up to 90 s for its config


def check_iot(iot):
    """Refuse an iot block that would collide or not fit its prefix."""
    net = ipaddress.ip_network(iot["prefix"])
    for p in iot["reservedPrefixes"]:
        if net.overlaps(ipaddress.ip_network(p)):
            raise Failed(f"iot prefix {net} overlaps {p} (a LAN or zt-eu prefix routed here)")
    addrs = {"address": iot["address"], **{f"hosts.{n}": h["ip"] for n, h in iot["hosts"].items()}}
    for what, a in addrs.items():
        if ipaddress.ip_address(a) not in net:
            raise Failed(f"iot {what} {a} is outside {net}")
    if ipaddress.ip_network(f"{iot['address']}/{iot['netmask']}", strict=False) != net:
        raise Failed(f"iot address/netmask {iot['address']}/{iot['netmask']} is not {net}")
    for n, h in iot["hosts"].items():
        if h.get("mac") is not None and not re.fullmatch(r"[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}", h["mac"]):
            raise Failed(f"iot host {n}: mac {h['mac']!r} is not aa:bb:cc:dd:ee:ff")
    ips = [h["ip"] for h in iot["hosts"].values()]
    if len(set(ips)) != len(ips):
        raise Failed("iot hosts share an ip")


def check_iot_routes(iot, routes, device):
    """Refuse an iot prefix overlapping a route the router has now.

    `routes`: `ip -4 route show table all` output: GL's policy tables
    (8000, 16800: VPN client, multi-WAN) too. Catches what
    reservedPrefixes can't (a WAN uplink's DHCP prefix changes with the
    upstream network). Routes on `device` inside the iot prefix are the
    router's own from an earlier run (main: the subnet; table local: its
    address and broadcasts) and fine; a local/broadcast entry for an
    iot address on any other device is an address there and collides.
    """
    net = ipaddress.ip_network(iot["prefix"])
    for line in routes.splitlines():
        w = line.split()
        if w and w[0] in ("unicast", "local", "broadcast", "multicast", "anycast",
                          "unreachable", "blackhole", "prohibit", "throw", "nat"):
            w = w[1:]
        if not w or w[0] == "default":
            continue
        try:
            dst = ipaddress.ip_network(w[0], strict=False)
        except ValueError:
            continue
        dev = w[w.index("dev") + 1] if "dev" in w[:-1] else None
        if dev is not None and dev == device and dst.version == net.version and dst.subnet_of(net):  # type: ignore[arg-type]
            continue
        if net.overlaps(dst):
            raise Failed(f"iot prefix {net} overlaps the router's route `{line.strip()}`")


def _first(have, stype, **match):
    """Section ids of `stype` whose single-valued options equal `match`, in uci order."""
    return [
        name for name, s in have.items()
        if s.get(".type") == stype and all(s.get(k) == [v] for k, v in match.items())
    ]


def desired_iot(iot, have, psk):
    """{config: {section: want}} for the iot network.

    `have`: {config: uci_show(...)} of firewall, network, wireless, dhcp.
    GL's prepared sections are adopted (exact=False keeps GL's own options
    such as ifname/macaddr), the zone and its two input rules by match;
    every other rule, redirect or forwarding naming zone iot is deleted:
    that is what keeps iot from reaching wan, zteu, zerotier or guest.
    """
    fw, net, wl, dhcp = (have[c] for c in ("firewall", "network", "wireless", "dhcp"))
    want = {"firewall": {}, "network": {}, "wireless": {}, "dhcp": {}}

    if "iot" not in net or net["iot"].get(".type") != "interface":
        raise Failed("no network.iot interface (GL's prepared IoT network)")
    want["network"]["iot"] = (
        "interface",
        {
            "disabled": "0",
            "proto": "static",
            "ipaddr": iot["address"],
            "netmask": iot["netmask"],
            # IPv4 only: no prefix delegated, none assigned.
            "delegate": "0",
            "ip6assign": None,
            "ip6class": None,
            "ip6prefix": None,
        },
        False,
    )

    for name in [iot["wifiIface"], *iot["offIfaces"]]:
        if wl.get(name, {}).get(".type") != "wifi-iface":
            raise Failed(f"no wireless.{name} wifi-iface (GL's prepared IoT Wi-Fi)")
    want["wireless"][iot["wifiIface"]] = (
        "wifi-iface",
        {
            "disabled": "0",
            "network": "iot",
            "mode": "ap",
            "ssid": iot["ssid"],
            "encryption": iot["encryption"],
            "key": psk,
            "hidden": "0",
            # PMF off: WPA2-only clients (the printer) without 802.11w.
            "ieee80211w": "0",
        },
        False,
    )
    for name in iot["offIfaces"]:
        want["wireless"][name] = ("wifi-iface", {"disabled": "1"}, False)

    if dhcp.get("iot", {}).get(".type") != "dhcp":
        raise Failed("no dhcp.iot section (GL's prepared IoT DHCP)")
    want["dhcp"]["iot"] = (
        "dhcp",
        {
            "interface": "iot", "ignore": "0", "dhcpv6": "disabled", "ra": "disabled", "ndp": "disabled",
            # Option 6 empty: the lease names no DNS server (the router
            # would not answer one anyway).
            "dhcp_option": ["6"],
        },
        False,
    )
    want["dhcp"].update({n: None for n in dhcp if n.startswith((IOT_HOST_PREFIX, IOT_LEASE_PREFIX))})
    for n, h in iot["hosts"].items():
        # A hosts entry; dnsmasq's expandhosts adds the local domain (.lan).
        want["dhcp"][f"{IOT_HOST_PREFIX}{n}"] = ("domain", {"name": n, "ip": h["ip"]})
        if h.get("mac"):
            want["dhcp"][f"{IOT_LEASE_PREFIX}{n}"] = (
                "host",
                {"name": n, "mac": h["mac"].lower(), "ip": h["ip"]},
            )

    zones = _first(fw, "zone", name="iot")
    zone = zones[0] if zones else "iot"
    want["firewall"].update({z: None for z in zones[1:]})
    want["firewall"][zone] = (
        "zone",
        {"name": "iot", "network": ["iot"], "input": "REJECT", "output": "ACCEPT", "forward": "REJECT"},
    )
    dhcp_rules = _first(fw, "rule", src="iot", name="Allow-DHCP")
    # DHCP is the only input: no DNS (GL's Allow-DNS goes with the other
    # iot rules below), so no DNS phone-home or tunnel through dnsmasq.
    keep = {
        (dhcp_rules or ["iot_dhcp"])[0]: (
            "rule",
            {"name": "Allow-DHCP", "src": "iot", "family": "ipv4", "proto": "udp",
             "dest_port": "67-68", "target": "ACCEPT"},
        ),
        "lan_iot": ("forwarding", {"src": "lan", "dest": "iot"}),
    }
    for name, s in fw.items():
        if name in keep or s.get(".type") not in ("rule", "redirect", "forwarding"):
            continue
        if "iot" in s.get("src", []) or "iot" in s.get("dest", []):
            want["firewall"][name] = None
    want["firewall"].update(keep)
    # GL's rule keeping LAN clients off the web UI on the iot address.
    for name in _first(fw, "rule", name="Block-LAN-mgmt-iot"):
        want["firewall"][name] = ("rule", {"dest_ip": iot["address"]}, False)

    # GL's route policy: interfaces in append_source_if get a forwarding
    # into the VPN client's zone when one is up (iot -> <vpn>), and
    # /etc/firewall.dns_order adds their L3 device (br-iot) to its DNS
    # dispatcher: with gl-dns-v2 force_dns=1 (set here) port 53 from
    # br-iot is REDIRECTed to dnsmasq, and fw3's "Accept port
    # redirections" (ct status dnat accept) lets that past the zone's
    # input REJECT. Dropping iot here is load-bearing for "no DNS".
    # Keep any others; nothing to do on firmware without the option.
    rp = have.get("route_policy", {}).get("global")
    if rp is not None and "iot" in rp.get("append_source_if", []):
        rest = [v for v in rp["append_source_if"] if v != "iot"]
        want["route_policy"] = {"global": (rp[".type"], {"append_source_if": rest or None}, False)}
    return want


IFF_UP = 0x1
FLAGS_MARK = "--- flags ---"
BRPORT_MARK = "--- brport ---"


def parse_wifi_up(text):
    """{ifname: essid} from `iwinfo` + `grep -H . /sys/class/net/*/flags`.

    An AP counts as up only if its link is administratively up (IFF_UP in
    /sys/class/net/<if>/flags), iwinfo shows `Mode: Master` and a quoted
    ESSID, and (when the probe includes it) it is a bridge port: an AP
    that dropped out of its bridge serves nobody. The ESSID alone says
    nothing on GL's MTK firmware: down slots
    (ra1 "HT_AP1", rax1 "HT_AP4", flags 0x1002) show one too. Not
    operstate either: the live rax0 is up but reports 'unknown'.
    """
    iw, _, rest = text.partition(FLAGS_MARK)
    flags_text, has_brport, brport_text = rest.partition(BRPORT_MARK)
    # Older callers/fixtures without the bridge-port part: don't require it.
    bridged = {m.group(1) for m in re.finditer(r"/sys/class/net/([^/\s]+)/brport", brport_text)}
    flags = {}
    for line in flags_text.splitlines():
        m = re.match(r"^/sys/class/net/([^/]+)/flags:(0x[0-9a-fA-F]+)\s*$", line.strip())
        if m:
            flags[m.group(1)] = int(m.group(2), 16)
    essid, mode, current = {}, {}, None
    for line in iw.splitlines():
        m = re.match(r'^(\S+)\s+ESSID: (?:"(.*)"|unknown)\s*$', line)
        if m:
            current = m.group(1)
            if m.group(2) is not None:
                essid[current] = m.group(2)
            continue
        m = re.match(r"^\s+Mode: (\S+)", line)
        if m and current is not None:
            mode[current] = m.group(1)
    return {
        i: e for i, e in essid.items()
        if mode.get(i) == "Master" and flags.get(i, 0) & IFF_UP
        and (not has_brport or i in bridged)
    }


def wifi_up(router):
    """{ifname: essid} of the APs that are up (see parse_wifi_up); None
    when the router can't be asked."""
    try:
        r = router.run(
            f"iwinfo 2>/dev/null && echo '{FLAGS_MARK}' && grep -H . /sys/class/net/*/flags"
            f" && echo '{BRPORT_MARK}' && for d in /sys/class/net/*/brport; do echo \"$d\"; done",
            check=False, timeout=60,
        )
    except Failed:
        return None
    if r.returncode != 0 or FLAGS_MARK not in r.stdout:
        return None
    return parse_wifi_up(r.stdout)


def wifi_expectation(wants, have_wireless):
    """(ifnames of the wifi-ifaces this run sets, SSIDs it turns on).

    Every other interface must come back exactly as before."""
    touched, ssids = set(), set()
    for name, section in wants.get("wireless", {}).items():
        if section is None or section[0] != "wifi-iface":
            continue
        touched.update(have_wireless.get(name, {}).get("ifname", []))
        opts = section[1]
        if opts.get("disabled") == "0" and opts.get("ssid"):
            ssids.add(opts["ssid"])
    return touched, ssids


def wifi_check(router, before, touched, ssids, settle=WIFI_SETTLE):
    """None once every interface up before (but those this run sets) is
    up again with the same SSID and every SSID in `ssids` is broadcast;
    else what is still missing after `settle` seconds.

    Only interfaces up before (by wifi_up's definition) are compared: an
    interface up before but missing now counts as gone; down slots may
    change what they show without mattering."""
    deadline = time.monotonic() + settle
    gone, missing = [], []
    good = 0
    while True:
        now = wifi_up(router)
        if now is not None:
            gone = sorted(f"{i} ({before[i]})" for i in set(before) - touched if now.get(i) != before[i])
            missing = sorted(ssids - set(now.values()))
            if not gone and not missing:
                good += 1
                if good >= 2:  # one good probe right after a reload can be a blip
                    return None
            else:
                good = 0
        else:
            good = 0
        if time.monotonic() > deadline:
            if now is None:
                return "iwinfo failed"
            return "; ".join(
                ([f"down since the change: {', '.join(gone)}"] if gone else [])
                + ([f"not broadcast: {', '.join(missing)}"] if missing else [])
            )
        time.sleep(5)


def iot_psk(iot, dry_run):
    """The PSK as a Secret, from `clan vars get amy <pskVar>` (repo root)."""
    got = subprocess.run(["clan", "vars", "get", "amy", iot["pskVar"]], capture_output=True, text=True)
    value = got.stdout.rstrip("\n") if got.returncode == 0 else ""
    if not value:
        if not dry_run:
            raise Failed(f"no iot psk: clan vars get amy {iot['pskVar']}: {got.stderr.strip()[-300:]}")
        print(f"iot: {iot['pskVar']} not readable (not generated yet?); key shown as a change", file=sys.stderr)
        value = None
    if value is not None and not 8 <= len(value) <= 63:
        raise Failed(f"iot psk from {iot['pskVar']} is {len(value)} chars; WPA2 wants 8-63")
    return Secret(IOT_PSK_ENV, value, iot["pskVar"])


# --- steps -------------------------------------------------------------


def key_id(line):
    parts = line.split()
    for i, p in enumerate(parts):
        if p.startswith(("ssh-", "ecdsa-", "sk-")) and i + 1 < len(parts):
            return (p, parts[i + 1])
    return None


def ensure_keys(router, dry_run):
    path = "/etc/dropbear/authorized_keys"
    have = router.run(f"cat {path} 2>/dev/null", check=False).stdout
    present = {key_id(l) for l in have.splitlines()}
    missing = [k for k in router.state["adminKeys"] if key_id(k) not in present]
    if not missing:
        return []
    if not dry_run:
        lines = "".join(f"{k}\n" for k in missing)
        router.run(
            f"mkdir -p /etc/dropbear && touch {path} && chmod 600 {path} && "
            f"{{ [ -z \"$(tail -c1 {path})\" ] || echo; printf %s {shlex.quote(lines)}; }} >> {path}"
        )
    return [f"authorized_keys: +{len(missing)} admin key(s)"]


def networks(router):
    r = router.run("zerotier-cli -j listnetworks")
    try:
        return {n["nwid"]: n for n in json.loads(r.stdout)}
    except (ValueError, KeyError) as e:
        raise Failed(f"{router.name}: zerotier-cli -j listnetworks: {e}") from None


def ensure_join(router, dry_run):
    s = router.state
    nwid, sec = s["networkId"], s["zerotierSection"]
    changes = []
    zt = uci_show(router, "zerotier")
    if sec not in zt:
        raise Failed(f"{router.name}: no uci section zerotier.{sec}")
    if nwid not in zt[sec].get("join", []):
        changes.append(f"zerotier.{sec}.join: +{nwid}")
        if not dry_run:
            # add_list turns a plain `option join` into a list, keeping it.
            router.run(f"uci add_list zerotier.{sec}.join={nwid} && uci commit zerotier")
    if nwid not in networks(router):
        changes.append(f"zerotier-cli join {nwid}")
        if not dry_run:
            router.run(f"zerotier-cli join {nwid}")
    return changes


def wait_network(router):
    """The zt-eu network once OK with the router's pinned addresses."""
    s = router.state
    want = {ipaddress.ip_address(s["ztIpv4"]), ipaddress.ip_address(s["ztIpv6"])}
    deadline = time.monotonic() + JOIN_TIMEOUT
    while True:
        n = networks(router).get(s["networkId"])
        if n:
            got = {ipaddress.ip_interface(a).ip for a in n.get("assignedAddresses", [])}
            if n.get("status") == "OK" and want <= got and n.get("portDeviceName"):
                return n
        if time.monotonic() > deadline:
            state = f"{n.get('status')} {n.get('assignedAddresses')}" if n else "not joined"
            raise Failed(
                f"{router.name}: zt-eu not OK with {s['ztIpv4']} and {s['ztIpv6']} after {JOIN_TIMEOUT}s ({state}); "
                "is edi deployed with this router in allowedIds and its pin?"
            )
        time.sleep(5)


def check_pending(router):
    """Fail if an interrupted run left a revert armed.

    Its timer would restore that run's snapshot whatever this run finds
    converged, and arming again would overwrite the snapshot. Run right
    after connect(), before anything is changed or snapshotted.
    """
    r = router.run(
        f"if [ -e {ARMED} ]; then "
        f"if kill -0 $(cat {PIDFILE} 2>/dev/null) 2>/dev/null; then echo live; else echo stale; fi; "
        f"else echo clear; fi",
        timeout=60,
    )
    status = r.stdout.strip()
    if status == "clear":
        return
    ssh = f"ssh root@{router.state['address']}"
    keep = f"{ssh} 'rm -f {ARMED}; kill $(cat {PIDFILE}) 2>/dev/null; rm -f {PIDFILE}'"
    # Everything a run may have touched (the snapshot is all of /etc/config).
    reload_all = "; ".join(f"{c} >/dev/null 2>&1" for c in RELOADS.values())
    restore = f"{ssh} 'cp -a {BACKUP}/. /etc/config/ && {{ {reload_all}; }}'"
    if status == "live":
        what = (f"a revert from an interrupted run is pending: when its timer fires it "
                f"restores /etc/config from {BACKUP} and reloads what that run touched "
                f"(network, Wi-Fi, dnsmasq, firewall)")
    else:
        what = (f"{ARMED} is set but no revert process runs (pid file {PIDFILE}): "
                f"an interrupted run's state is unknown")
    raise Failed(
        f"{router.name}: {what}. Nothing done. Check the router's config, then either keep it: "
        f"{keep}; or restore the snapshot: {keep} && {restore}; and rerun."
    )


def arm(router, seconds, reloads):
    restore = "\n".join(f"{c} >/dev/null 2>&1" for c in reloads)
    script = f"""#!/bin/sh
sleep {seconds}
[ -f {ARMED} ] || exit 0
rm -f {ARMED}
cp -a {BACKUP}/. /etc/config/
{restore}
logger -t site-routers-apply "revert fired: restored /etc/config from {BACKUP}"
"""
    # Never overwrite the snapshot of a revert still pending (check_pending
    # has already refused one; this guards the race).
    router.run(
        f"if [ -e {ARMED} ]; then echo 'a revert is already pending' >&2; exit 1; fi && "
        f"rm -rf {BACKUP} && mkdir -p {BACKUP} && cp -a /etc/config/. {BACKUP}/ && "
        f"printf %s {shlex.quote(script)} > {REVERT} && chmod 700 {REVERT} && touch {ARMED} && "
        f"rm -f {PIDFILE} && start-stop-daemon -S -b -m -p {PIDFILE} -x /bin/sh -- {REVERT}"
    )


def revert_now(router):
    """Fire the armed revert right away: "now" if it was started,
    "fired" if the armed one already ran (ARMED gone: its deadline passed
    during slow reloads), None if the router could not be asked.

    Runs a copy of the revert script without its sleep, detached on the
    router (a network reload may drop this ssh session mid-restore), and
    stops the sleeping original. If this ssh fails, the original still
    fires at its deadline.
    """
    r = router.run(
        f"{{ [ -e {ARMED} ] || exit 3; }} && "
        f"sed '2s/^sleep .*/:/' {REVERT} > {REVERT}.now && chmod 700 {REVERT}.now && "
        f"rm -f {PIDFILE}.now && start-stop-daemon -S -b -m -p {PIDFILE}.now -x /bin/sh -- {REVERT}.now && "
        # The sleeping original would otherwise wake into a later run's
        # ARMED and REVERT (sh reads its script as it goes).
        f"{{ kill $(cat {PIDFILE}) 2>/dev/null; rm -f {PIDFILE}; true; }}",
        check=False,
        timeout=60,
    )
    return {0: "now", 3: "fired"}.get(r.returncode)


def disarm(router):
    """Over a fresh connection: proves the router is still reachable."""
    r = router.run(
        f"rm {ARMED} && {{ kill $(cat {PIDFILE}) 2>/dev/null; rm -f {PIDFILE}; true; }}",
        check=False,
        timeout=60,
    )
    return r.returncode == 0


def ensure_uci(router, wants, dry_run, revert_after, secrets=()):
    """Converge {config: {section: want}} in one armed change.

    One snapshot and one revert cover every config touched; after the
    commit the touched configs are reloaded in RELOADS order. A dry run
    lists the exact uci commands (secrets only as their $variable).
    """
    cmds, changes, touched, haves = [], [], [], {}
    for config, sections in wants.items():
        have = haves[config] = uci_show(router, config)
        for name, section in sections.items():
            c = section_commands(config, name, section, have.get(name))
            if c:
                changes.append(f"{config}.{name}: " + ("delete" if section is None else "set"))
                if dry_run:
                    changes += [f"    {x}" for x in c]
                cmds += c
                if config not in touched:
                    touched.append(config)
    slow = SLOW_CONFIGS & set(touched)
    if slow and revert_after < SLOW_REVERT_AFTER:
        # A network/Wi-Fi reload plus the Wi-Fi check outlast a short
        # revert, which would then fire on a good change.
        print(f"{router.name}: {'/'.join(sorted(slow))} changes: revert after {SLOW_REVERT_AFTER}s "
              f"instead of {revert_after}s", file=sys.stderr)
        revert_after = SLOW_REVERT_AFTER
    if not cmds or dry_run:
        return changes
    reloads = [RELOADS[c] for c in RELOADS if c in touched]
    wifi_before = None
    if "wireless" in touched or "network" in touched:
        wifi_before = wifi_up(router)
        if wifi_before is None:
            raise Failed(f"{router.name}: iwinfo failed; nothing changed (needed for the Wi-Fi check)")
    arm(router, revert_after, reloads)
    print(f"{router.name}: revert armed ({revert_after}s), applying {len(cmds)} uci command(s)", file=sys.stderr)
    needed = [s for s in secrets if any(f"${s.env}" in c for c in cmds)]
    try:
        router.run(" && ".join(cmds + [f"uci commit {c}" for c in touched]), secrets=needed)
    except Failed:
        router.run("; ".join(f"uci revert {c}" for c in touched), check=False)
        router.run(f"rm -f {ARMED}; kill $(cat {PIDFILE}) 2>/dev/null", check=False)
        raise
    # A dropped session here is not fatal by itself (a reload may drop it):
    # the fresh connection below decides.
    for cmd in reloads:
        r = router.run(f"{cmd} >/dev/null 2>&1", check=False, timeout=180)
        if r.returncode != 0:
            print(f"{router.name}: {cmd} exited {r.returncode}: {r.stderr.strip()}", file=sys.stderr)
    time.sleep(5)
    if wifi_before is not None:
        # The router is reached over WAN/zerotier, so a dead LAN radio
        # would not stop the disarm below: check the SSIDs first.
        wifi_touched, ssids = wifi_expectation(wants, haves.get("wireless", {}))
        problem = wifi_check(router, wifi_before, wifi_touched, ssids)
        if problem:
            how = revert_now(router)
            if how == "now":
                raise Failed(
                    f"{router.name}: Wi-Fi not healthy after the change ({problem}); reverted now: "
                    f"the router restores /etc/config from {BACKUP} and reloads {', '.join(touched)}"
                )
            if how == "fired":
                raise Failed(
                    f"{router.name}: Wi-Fi not healthy after the change ({problem}); the armed revert "
                    f"already restored /etc/config from {BACKUP} ({revert_after}s passed during the reloads)"
                )
            raise Failed(
                f"{router.name}: Wi-Fi not healthy after the change ({problem}); immediate revert failed, "
                f"revert left armed (it may already have run): the router restores /etc/config from "
                f"{BACKUP} {revert_after}s after arming"
            )
        print(f"{router.name}: Wi-Fi ok (every SSID up before is up, new ones broadcast)", file=sys.stderr)
    for _ in range(6):
        if disarm(router):
            print(f"{router.name}: fresh ssh ok, revert disarmed", file=sys.stderr)
            return changes
        time.sleep(10)
    raise Failed(
        f"{router.name}: no fresh ssh after the change; the router restores /etc/config "
        f"from {BACKUP} {revert_after}s after arming"
    )


def check_addresses(router, device):
    s = router.state
    out = router.run(f"ip -o addr show dev {device}").stdout
    have = {ipaddress.ip_interface(w[i + 1]).ip for w in map(str.split, out.splitlines())
            for i, x in enumerate(w) if x in ("inet", "inet6")}
    missing = {ipaddress.ip_address(s["ztIpv4"]), ipaddress.ip_address(s["ztIpv6"])} - have
    if missing:
        raise Failed(f"{router.name}: {device} lacks {sorted(map(str, missing))} although zerotier assigned them")


def apply(state, dry_run, revert_after, log):
    iot = state.get("iot")
    if iot:
        check_iot(iot)
    router = Router(state, log)
    router.connect()
    check_pending(router)
    changes = ensure_keys(router, dry_run)
    changes += ensure_join(router, dry_run)
    if dry_run and state["networkId"] not in networks(router):
        device = "<zt-eu device>"
    else:
        device = wait_network(router)["portDeviceName"]
    wants = {"firewall": desired_firewall(state, device, uci_show(router, "firewall"))}
    secrets = []
    if iot:
        psk = iot_psk(iot, dry_run)
        secrets.append(psk)
        have = {c: uci_show(router, c) for c in ("firewall", "network", "wireless", "dhcp", "route_policy")}
        iot_dev = (have["network"].get("iot", {}).get("device") or [None])[0]
        check_iot_routes(iot, router.run("ip -4 route show table all", timeout=60).stdout, iot_dev)
        for config, sections in desired_iot(iot, have, psk).items():
            wants.setdefault(config, {}).update(sections)
    changes += ensure_uci(router, wants, dry_run, revert_after, secrets)
    if not dry_run:
        check_addresses(router, device)
    return changes


def main():
    parser = argparse.ArgumentParser(prog="site-routers-apply", description=__doc__.split("\n\n")[1])
    parser.add_argument("--state", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true", help="report what would change, change nothing")
    parser.add_argument("--revert-after", type=int, default=300, metavar="SECONDS",
                        help="arm the automatic config revert for this long (default 300; "
                             f"at least {SLOW_REVERT_AFTER} when network or Wi-Fi changes)")
    parser.add_argument("-v", "--verbose", action="store_true", help="log every ssh command")
    parser.add_argument("routers", nargs="*", metavar="ROUTER", help="router or site name (default: all)")
    args = parser.parse_args()

    with open(args.state) as f:
        states = json.load(f)
    by_name = {}
    for site, s in states.items():
        by_name[site] = by_name[s["name"]] = site
    unknown = [r for r in args.routers if r not in by_name]
    if unknown:
        parser.error(f"unknown router(s) {unknown}; known: {sorted(by_name)}")
    sites = [by_name[r] for r in args.routers] or list(states)
    log = (lambda m: print(m, file=sys.stderr)) if args.verbose else (lambda m: None)

    failed = False
    for site in dict.fromkeys(sites):
        s = states[site]
        try:
            changes = apply(s, args.dry_run, args.revert_after, log)
        except Failed as e:
            print(f"{s['name']}: FAILED: {e}", file=sys.stderr)
            failed = True
            continue
        verb = "would change" if args.dry_run else "changed"
        if changes:
            print(f"{s['name']}: {verb}:")
            for c in changes:
                print(f"  {c}")
        else:
            print(f"{s['name']}: no changes")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
