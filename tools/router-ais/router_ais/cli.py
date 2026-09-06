"""router-ais: manage the AIS ZTE F6107A router from the command line."""

import argparse
import ipaddress
import json
import os
import subprocess
import sys

from .client import PROTO_BY_NAME, Router, RouterError, Rule

DEFAULT_HOST = "192.168.1.1"
PROTECTED_ADDRESS = ipaddress.IPv6Address("2405:9800:b901:94e3::feed:da7a")
CLAN_VAR = ["clan", "vars", "get", "amy", "router-ais/password"]


def password() -> str:
    pw = os.environ.get("ROUTER_AIS_PASSWORD")
    if pw:
        return pw
    try:
        out = subprocess.run(CLAN_VAR, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        detail = e.stderr.strip().splitlines()[-1] if getattr(e, "stderr", None) else str(e)
        raise RouterError(f"cannot read password via `{' '.join(CLAN_VAR)}`: {detail}") from None
    pw = out.strip()
    if not pw:
        raise RouterError("clan vars returned an empty password")
    return pw


def rule_dict(r: Rule) -> dict:
    return {
        "inst_id": r.inst_id,
        "name": r.name,
        "enabled": r.enabled,
        "target": r.target,
        "ip_version": r.ip_version,
        "protocol": r.protocol,
        "src": r.src,
        "dst": r.dst,
        "src_ports": r.src_ports,
        "dst_ports": r.dst_ports,
        "ingress": r.ingress,
        "egress": r.egress,
        "dscp": r.dscp,
        "order": r.order,
    }


def print_rules(rules: list[Rule], as_json: bool) -> None:
    if as_json:
        print(json.dumps([rule_dict(r) for r in rules], indent=2))
        return
    if not rules:
        print("no IP filter rules")
        return
    cols = ["#", "inst", "name", "on", "target", "ipv", "proto", "src", "dst", "sport", "dport", "in", "out", "order"]
    rows = [
        [
            str(i),
            r.inst_id.removeprefix("DEV.FW.CHAIN1."),
            r.name,
            "yes" if r.enabled else "no",
            r.target,
            r.ip_version,
            r.protocol,
            r.src,
            r.dst,
            r.src_ports,
            r.dst_ports,
            r.ingress,
            r.egress,
            r.order,
        ]
        for i, r in enumerate(rules, 1)
    ]
    widths = [max(len(c), *(len(row[i]) for row in rows)) for i, c in enumerate(cols)]
    for line in [cols, *rows]:
        print("  ".join(v.ljust(w) for v, w in zip(line, widths)).rstrip())


def parse_port(spec: str) -> tuple[int, int]:
    lo, _, hi = spec.partition("-")
    try:
        a, b = int(lo), int(hi or lo)
    except ValueError:
        raise argparse.ArgumentTypeError(f"bad port {spec!r}: use N or N-M") from None
    if not 1 <= a <= b <= 65535:
        raise argparse.ArgumentTypeError(f"bad port range {spec!r}")
    return a, b


def find_rule(rules: list[Rule], key: str) -> Rule:
    if key.isdigit() and 1 <= int(key) <= len(rules):
        return rules[int(key) - 1]
    hits = [r for r in rules if key in (r.name, r.inst_id, r.inst_id.removeprefix("DEV.FW.CHAIN1."))]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise RouterError(f"no rule named {key!r} (use `ipv6-rules list`)")
    raise RouterError(f"{key!r} matches several rules; use the # or inst column")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="router-ais", description="Manage the AIS ZTE F6107A router.")
    p.add_argument("--host", default=DEFAULT_HOST, help=f"router address (default {DEFAULT_HOST})")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    p.add_argument("--no-force", action="store_true", help="do not log out another active web session")
    p.add_argument("-v", "--verbose", action="store_true", help="log the login flow to stderr")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("login", help="log in, print model/firmware, log out")

    rules = sub.add_parser("ipv6-rules", help="IPv6 inbound-allow (IP filter) rules")
    rsub = rules.add_subparsers(dest="rcmd", required=True)
    rsub.add_parser("list", help="show all IP filter rules")

    add = rsub.add_parser("add", help="add an IPv6 allow rule for one address")
    add.add_argument("--address", required=True, type=ipaddress.IPv6Address, help="LAN IPv6 address to expose")
    add.add_argument("--proto", choices=sorted(PROTO_BY_NAME), default="any", help="protocol (default any)")
    add.add_argument("--port", type=parse_port, help="destination port N or N-M (needs --proto tcp|udp|both)")
    add.add_argument("--name", help="rule name (default derived from the address)")

    rm = rsub.add_parser("delete", help="delete a rule by #, inst id or name")
    rm.add_argument("rule", help="row number, inst id (IPF2) or name from `list`")
    rm.add_argument("--i-know", action="store_true", help=f"allow deleting the rule protecting {PROTECTED_ADDRESS}")
    return p


def run(args: argparse.Namespace) -> int:
    log = (lambda m: print(f"router-ais: {m}", file=sys.stderr)) if args.verbose else (lambda m: None)
    if args.cmd == "ipv6-rules" and args.rcmd == "add" and args.port and args.proto in ("any", "icmpv6"):
        raise RouterError("--port needs --proto tcp, udp or both")
    router = Router(args.host, password(), force=not args.no_force, log=log)
    router.login()
    try:
        if args.cmd == "login":
            info = router.device_info()
            if args.json:
                print(json.dumps({"session": "ok", **info}))
            else:
                print(
                    f"session ok: {info.get('ModelName', '?')} firmware {info.get('SoftwareVer', '?')} "
                    f"hardware {info.get('HardwareVer', '?')} serial {info.get('SerialNumber', '?')}"
                )
            return 0
        if args.rcmd == "list":
            print_rules(router.ip_rules(), args.json)
            return 0
        if args.rcmd == "add":
            name = args.name or f"v6-{args.address.exploded[-4:]}"
            rules = router.ip_rules()
            if any(r.name == name for r in rules):
                raise RouterError(f"a rule named {name!r} already exists")
            inst = router.add_ipv6_allow(str(args.address), args.proto, args.port, name, order=len(rules) + 1)
            created = next((r for r in router.ip_rules() if r.inst_id == inst), None)
            if created is None:
                raise RouterError(f"router returned {inst!r} but the rule is not listed")
            if args.json:
                print(json.dumps(rule_dict(created)))
            else:
                print(f"added {created.inst_id} {created.name}: {created.protocol} -> {created.dst} port {created.dst_ports}")
            return 0
        if args.rcmd == "delete":
            rules = router.ip_rules()
            rule = find_rule(rules, args.rule)
            if rule.address and ipaddress.IPv6Address(rule.address) == PROTECTED_ADDRESS and not args.i_know:
                raise RouterError(
                    f"refusing to delete {rule.inst_id} {rule.name!r}: it protects {PROTECTED_ADDRESS} (pass --i-know)"
                )
            router.delete_rule(rule)
            if any(r.inst_id == rule.inst_id for r in router.ip_rules()):
                raise RouterError(f"router accepted the delete but {rule.inst_id} is still listed")
            if args.json:
                print(json.dumps({"deleted": rule_dict(rule)}))
            else:
                print(f"deleted {rule.inst_id} {rule.name}")
            return 0
        raise RouterError(f"unknown command {args.cmd} {args.rcmd}")
    finally:
        router.logout()


def main() -> None:
    args = build_parser().parse_args()
    try:
        sys.exit(run(args))
    except RouterError as e:
        print(f"router-ais: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
