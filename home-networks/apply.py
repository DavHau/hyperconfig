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
     armed on the router: after --revert-after seconds (default 300) it
     restores the snapshot and reloads the firewall, unless a fresh
     ssh connection made after the reload has disarmed it. Finally checks
     that the zt-eu addresses are on the device.

ssh is root@<address> (the old zerotier net) with your keys; a router
without them is reached with its password from `clan vars get amy
<passwordVar>` (run from the repo root) through sshpass, once: step 1 then
installs the keys. Host keys are pinned in
$XDG_STATE_HOME/site-routers/known_hosts. A failing router does not stop
the others; the exit status is 1 if any failed.
"""

import argparse
import ipaddress
import json
import os
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

    def run(self, command, check=True, timeout=120):
        self.log(f"{self.name}$ {command}")
        env = dict(os.environ, SSHPASS=self.password) if self.password is not None else None
        try:
            r = subprocess.run(
                [*self._argv(), command], capture_output=True, text=True, timeout=timeout, env=env
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
        var = self.state["passwordVar"]
        got = subprocess.run(["clan", "vars", "get", "amy", var], capture_output=True, text=True)
        if got.returncode != 0 or not got.stdout.strip():
            raise Failed(f"{self.name}: key login refused and no password: clan vars get amy {var}: {got.stderr.strip()}")
        self.password = got.stdout.rstrip("\n")
        print(f"{self.name}: no key login, using the password from {var}", file=sys.stderr)
        self.run("true", timeout=60)


# --- uci ---------------------------------------------------------------


def uci_show(router, config):
    """{section: {".type": type, option: [values]}} of one uci config."""
    out = router.run(f"uci -q show {config}", check=False).stdout
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


def section_commands(config, name, want, have):
    """uci commands turning section `name` from `have` into `want` (None = absent)."""
    q = shlex.quote
    if want is None:
        return [f"uci delete {config}.{name}"] if have is not None else []
    stype, options = want
    if have is not None and have.get(".type") != stype:
        cmds, have = [f"uci delete {config}.{name}"], None
    else:
        cmds = []
    if have is None:
        cmds.append(f"uci set {config}.{name}={stype}")
        have = {}
    for opt in sorted(set(have) - set(options) - {".type"}):
        cmds.append(f"uci delete {config}.{name}.{opt}")
    for opt, value in options.items():
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


def arm(router, seconds):
    script = f"""#!/bin/sh
sleep {seconds}
[ -f {ARMED} ] || exit 0
rm -f {ARMED}
cp -a {BACKUP}/. /etc/config/
/etc/init.d/firewall reload
logger -t site-routers-apply "no fresh ssh after the change: restored /etc/config from {BACKUP}"
"""
    router.run(
        f"rm -rf {BACKUP} && mkdir -p {BACKUP} && cp -a /etc/config/. {BACKUP}/ && "
        f"printf %s {shlex.quote(script)} > {REVERT} && chmod 700 {REVERT} && touch {ARMED} && "
        f"start-stop-daemon -S -b -m -p {PIDFILE} -x /bin/sh -- {REVERT}"
    )


def disarm(router):
    """Over a fresh connection: proves the router is still reachable."""
    r = router.run(
        f"rm {ARMED} && {{ kill $(cat {PIDFILE}) 2>/dev/null; rm -f {PIDFILE}; true; }}",
        check=False,
        timeout=60,
    )
    return r.returncode == 0


def ensure_firewall(router, device, dry_run, revert_after):
    have = uci_show(router, "firewall")
    cmds, changes = [], []
    for name, section in desired_firewall(router.state, device, have).items():
        c = section_commands("firewall", name, section, have.get(name))
        if c:
            changes.append(f"firewall.{name}: " + ("delete" if section is None else "set"))
            cmds += c
    if not cmds or dry_run:
        return changes
    arm(router, revert_after)
    print(f"{router.name}: revert armed ({revert_after}s), applying {len(cmds)} uci command(s)", file=sys.stderr)
    try:
        router.run(" && ".join(cmds + ["uci commit firewall"]))
    except Failed:
        router.run("uci revert firewall", check=False)
        router.run(f"rm -f {ARMED}; kill $(cat {PIDFILE}) 2>/dev/null", check=False)
        raise
    # A dropped session here is not fatal by itself: the fresh connection
    # below decides.
    r = router.run("/etc/init.d/firewall reload >/dev/null 2>&1", check=False, timeout=180)
    if r.returncode != 0:
        print(f"{router.name}: firewall reload exited {r.returncode}: {r.stderr.strip()}", file=sys.stderr)
    time.sleep(5)
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
    router = Router(state, log)
    router.connect()
    changes = ensure_keys(router, dry_run)
    changes += ensure_join(router, dry_run)
    if dry_run and state["networkId"] not in networks(router):
        device = "<zt-eu device>"
    else:
        device = wait_network(router)["portDeviceName"]
    changes += ensure_firewall(router, device, dry_run, revert_after)
    if not dry_run:
        check_addresses(router, device)
    return changes


def main():
    parser = argparse.ArgumentParser(prog="site-routers-apply", description=__doc__.split("\n\n")[1])
    parser.add_argument("--state", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true", help="report what would change, change nothing")
    parser.add_argument("--revert-after", type=int, default=300, metavar="SECONDS",
                        help="arm the automatic config revert for this long (default 300)")
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
