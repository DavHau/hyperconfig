"""router-playa-isp --state STATE.json [--dry-run] [--allow-pool-change]

Converges the DHCP server of playa's ISP router (Orange Livebox Fibra,
Arcadyan PRV3399B; see ../PROTOCOL.md) to the `ispRouter` of playa in
home-networks/sites.nix: the pool (start, end, lease time) and the static
reservations (MAC -> IP). Idempotent: reads the current state, prints the
differences and changes only those; a second run reports no changes.
Reservations not declared are deleted.

Before the first write the current DHCP config is saved to
/tmp/playa-isp-before-<timestamp>.json. Pool changes are refused unless
--allow-pool-change is given: the web UI warns that changing the pool
restarts the router and deletes the NAT, DMZ and DHCP reservation rules.
The admin password comes from $ROUTER_PLAYA_ISP_PASSWORD or else from
`clan vars get amy <passwordVar>` (run from the repo root). The web session
is logged out at the end (the UI keeps one admin session).
"""

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
import time

from .client import LanState, Router, RouterError

NAME = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
MAC = re.compile(r"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")
POOL_CFG = {"poolStart": "dhcp_startip1", "poolEnd": "dhcp_endip1", "leaseTime": "leasetime1"}


def password(var: str) -> str:
    pw = os.environ.get("ROUTER_PLAYA_ISP_PASSWORD")
    if pw:
        return pw
    argv = ["clan", "vars", "get", "amy", var]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        detail = e.stderr.strip().splitlines()[-1] if getattr(e, "stderr", None) else str(e)
        raise RouterError(f"cannot read the password via `{' '.join(argv)}`: {detail}") from None
    pw = out.rstrip("\n")
    if not pw:
        raise RouterError(f"`{' '.join(argv)}` returned an empty password")
    return pw


def desired_reservations(want: dict, lan: ipaddress.IPv4Interface) -> dict[str, tuple[str, str]]:
    """MAC (upper-case) -> (ip, name), validated the way the UI validates."""
    out: dict[str, tuple[str, str]] = {}
    ips: set[str] = set()
    for name, r in want.items():
        mac = r["mac"].upper()
        ip = ipaddress.IPv4Address(r["ip"])
        if not NAME.match(name):
            raise RouterError(f"reservation {name!r}: name must match {NAME.pattern} (it is stored comma-separated)")
        if not MAC.match(mac):
            raise RouterError(f"reservation {name}: bad MAC {r['mac']!r}")
        if ip not in lan.network or ip in (lan.ip, lan.network.network_address, lan.network.broadcast_address):
            raise RouterError(f"reservation {name}: {ip} is not a host address of {lan.network} other than the router's")
        if mac in out:
            raise RouterError(f"reservation {name}: MAC {mac} declared twice")
        if str(ip) in ips:
            raise RouterError(f"reservation {name}: IP {ip} declared twice")
        ips.add(str(ip))
        out[mac] = (str(ip), name)
    return out


def plan(state: LanState, want: dict) -> tuple[dict[str, str], list[tuple[str, dict[str, str]]]]:
    """(pool settings to change, reservation steps): each step one apply.cgi post."""
    if state.value("dhcp_enable1") != "1":
        raise RouterError("the router's DHCP server is disabled; not managed here, enable it in the UI")
    lan = ipaddress.IPv4Interface(f"{state.value('lan_ip1')}/{state.value('lan_mask1')}")
    dhcp = want["dhcp"]

    pool = {}
    for key, cfg in POOL_CFG.items():
        value = str(dhcp[key])
        if state.value(cfg) != value:
            pool[cfg] = value
    for key in ("poolStart", "poolEnd"):
        if ipaddress.IPv4Address(dhcp[key]) not in lan.network:
            raise RouterError(f"{key} {dhcp[key]} is outside {lan.network}")

    wanted = desired_reservations(dhcp["reservations"], lan)
    steps: list[tuple[str, dict[str, str]]] = []
    free = state.free_slots()
    for r in state.reservations:
        if r.mac not in wanted:
            if r.ip == state.value("client_ip") and state.value("dmz_enable") == "1":
                raise RouterError(f"reservation {r.name} ({r.ip}) is the DMZ host; change the DMZ first")
            steps.append((f"delete {r.name}: {r.ip} {r.mac} (slot {r.slot})", {state.slot_name(r.slot): ""}))
            free.append(r.slot)
    free.sort()
    have = {r.mac: r for r in state.reservations}
    for mac, (ip, name) in wanted.items():
        value = f"{ip},{mac},{name}"
        r = have.get(mac)
        if r is None:
            slot = free.pop(0) if free else None
            if slot is None:
                raise RouterError("no free reservation slot (the router holds 32)")
            steps.append((f"add {name}: {ip} {mac} (slot {slot})", {state.slot_name(slot): value}))
        elif (r.ip, r.name) != (ip, name):
            steps.append((f"change {name}: {r.name} {r.ip} -> {name} {ip}, {mac} (slot {r.slot})", {state.slot_name(r.slot): value}))
    return pool, steps


def show(state: LanState, want: dict, pool: dict[str, str], steps: list) -> None:
    print(
        f"pool: {state.value('dhcp_startip1')}-{state.value('dhcp_endip1')}, "
        f"lease {state.value('leasetime1')}s; {len(state.reservations)} reservation(s)"
    )
    for cfg, value in pool.items():
        print(f"  pool {cfg}: {state.value(cfg)} -> {value}")
    for what, _ in steps:
        print(f"  {what}")
    leased = {l.mac: l for l in state.leases}
    for name, r in want["dhcp"]["reservations"].items():
        lease = leased.get(r["mac"].upper())
        if lease and lease.ip != r["ip"]:
            print(f"  note: {name} holds a lease on {lease.ip}; it moves to {r['ip']} when it next renews (lease {lease.lease_time}s)")
    if not pool and not steps:
        print("no changes")


def converge(router: Router, want: dict, dry_run: bool, allow_pool: bool) -> None:
    state = router.read_lan()
    pool, steps = plan(state, want)
    show(state, want, pool, steps)
    if not pool and not steps:
        return
    if pool and not allow_pool:
        raise RouterError("the pool differs: refusing without --allow-pool-change (the router restarts and drops reservations)")
    if dry_run:
        print("dry run: nothing changed")
        return

    backup = f"/tmp/playa-isp-before-{time.strftime('%Y%m%dT%H%M%S')}.json"
    with open(backup, "w") as f:
        json.dump(state.snapshot(), f, indent=2)
    print(f"saved the current DHCP config to {backup}")

    if pool:
        print("applying the pool")
        router.apply(state, pool)
        state = router.read_lan()
        _, steps = plan(state, want)
    for what, changes in steps:
        print(f"applying: {what}")
        router.apply(state, changes)
        state = router.read_lan()

    pool, steps = plan(state, want)
    if pool or steps:
        show(state, want, pool, steps)
        raise RouterError("the router does not show the declared state after applying")
    print("verified: the router matches")


def main() -> None:
    parser = argparse.ArgumentParser(prog="router-playa-isp", description=__doc__.split("\n\n")[1])
    parser.add_argument("--state", required=True, help="desired state (JSON of sites.nix playa.ispRouter)")
    parser.add_argument("--dry-run", action="store_true", help="report what would change, change nothing")
    parser.add_argument("--allow-pool-change", action="store_true", help="also apply pool differences (restarts the router)")
    args = parser.parse_args()
    with open(args.state) as f:
        want = json.load(f)
    try:
        with Router(want["address"], want["user"], password(want["passwordVar"])) as router:
            converge(router, want, args.dry_run, args.allow_pool_change)
    except RouterError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
