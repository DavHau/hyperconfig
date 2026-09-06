"""router-cm-beryl: manage IPv6 inbound-allow rules on the GL.iNet Beryl from the command line."""

import argparse
import ipaddress
import json
import os
import subprocess
import sys

from .client import PORT_PROTOS, PROTOS, Router, RouterError, Rule

DEFAULT_HOST = "192.168.8.1"
PROTECTED_ADDRESS = ipaddress.IPv6Address("2405:9800:b901:94e3::feed:da7a")
CLAN_VAR = ["clan", "vars", "get", "amy", "router-cm-beryl/password"]


def password() -> str:
    pw = os.environ.get("ROUTER_CM_BERYL_PASSWORD")
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
        "section": r.section,
        "name": r.name,
        "enabled": r.enabled,
        "src": r.src,
        "dest": r.dest,
        "family": r.family,
        "dest_ip": r.dest_ip,
        "proto": r.proto,
        "dest_port": r.dest_port,
        "target": r.target,
    }


def print_table(cols: list[str], rows: list[list[str]]) -> None:
    widths = [max(len(c), *(len(row[i]) for row in rows)) for i, c in enumerate(cols)]
    for line in [cols, *rows]:
        print("  ".join(v.ljust(w) for v, w in zip(line, widths)).rstrip())


def print_rules(rules: list[Rule], as_json: bool) -> None:
    if as_json:
        print(json.dumps([rule_dict(r) for r in rules], indent=2))
        return
    if not rules:
        print("no wan IPv6 rules")
        return
    cols = ["section", "name", "on", "src", "dest", "family", "dest_ip", "proto", "dport", "target"]
    rows = [
        [
            r.section,
            r.name or "-",
            "yes" if r.enabled else "no",
            r.src,
            r.dest or "-",
            r.family,
            r.dest_ip or "-",
            r.proto,
            r.dest_port or "-",
            r.target,
        ]
        for r in rules
    ]
    print_table(cols, rows)


def parse_port(spec: str) -> str:
    lo, sep, hi = spec.partition("-")
    try:
        a = int(lo)
        b = int(hi) if sep else a
    except ValueError:
        raise argparse.ArgumentTypeError(f"bad port {spec!r}: expected N or N-M") from None
    if not (1 <= a <= 65535 and 1 <= b <= 65535 and a <= b):
        raise argparse.ArgumentTypeError(f"bad port {spec!r}: expected N or N-M within 1-65535")
    return f"{a}-{b}" if sep else str(a)


def find_rule(rules: list[Rule], key: str) -> Rule:
    hits = [r for r in rules if r.section == key]
    if not hits:
        hits = [r for r in rules if r.name == key]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise RouterError(f"no wan IPv6 rule with section id or name {key!r}")
    raise RouterError(f"{key!r} names several rules; use the section id: " + ", ".join(r.section for r in hits))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="router-cm-beryl", description="Manage the GL.iNet Beryl (GL-MT3000) firewall over ssh.")
    p.add_argument("--host", default=DEFAULT_HOST, help=f"router address (default {DEFAULT_HOST})")
    p.add_argument("-J", "--jump", metavar="USER@HOST", help="ssh jump host, e.g. root@bam.d (default none)")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    p.add_argument("-v", "--verbose", action="store_true", help="log ssh commands to stderr")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info", help="print model, firmware, firewall flavour and zones")

    rules = sub.add_parser("ipv6-rules", help="IPv6 inbound-allow (wan -> lan) rules")
    rsub = rules.add_subparsers(dest="rcmd", required=True)
    rsub.add_parser("list", help="show firewall rules with src=wan and family ipv6/any")

    add = rsub.add_parser("add", help="add a wan->lan ACCEPT rule for one IPv6 address")
    add.add_argument("--address", required=True, type=ipaddress.IPv6Address, help="LAN IPv6 address to expose")
    add.add_argument("--proto", choices=PROTOS, default="all", help="protocol (default all: every protocol, the host firewall decides)")
    add.add_argument("--port", type=parse_port, help="destination port N or N-M (needs --proto tcp|udp|tcpudp)")
    add.add_argument("--name", help="rule name (default omp-<last 4 hex of address>)")

    rm = rsub.add_parser("delete", help="delete a rule by section id or name")
    rm.add_argument("rule", help="section id (cfg1234ab) or name from `list`")
    rm.add_argument("--i-know", action="store_true", help=f"allow deleting a rule for {PROTECTED_ADDRESS}")
    return p


def run(args: argparse.Namespace) -> int:
    log = (lambda m: print(f"router-cm-beryl: {m}", file=sys.stderr)) if args.verbose else (lambda m: None)
    if args.cmd == "ipv6-rules" and args.rcmd == "add" and args.port and args.proto not in PORT_PROTOS:
        raise RouterError("--port needs --proto tcp, udp or tcpudp")
    router = Router(args.host, password(), jump=args.jump, log=log)

    if args.cmd == "info":
        board = router.board()
        info = {
            "model": board.get("model"),
            "board_name": board.get("board_name"),
            "hostname": board.get("hostname"),
            "kernel": board.get("kernel"),
            "openwrt": board.get("release", {}).get("description", "").strip(),
            "gl_version": router.gl_version(),
            "firewall": router.firewall_flavour(),
            "zones": router.zones(),
        }
        if args.json:
            print(json.dumps(info, indent=2))
            return 0
        print(f"{info['model']} ({info['board_name']}) hostname {info['hostname']}")
        print(f"GL firmware {info['gl_version'] or '?'}, {info['openwrt'] or 'OpenWrt ?'}, kernel {info['kernel']}")
        print(f"firewall: {info['firewall']}")
        print("zones:")
        print_table(
            ["name", "networks", "input", "output", "forward"],
            [[z["name"], ",".join(z["network"]) or "-", z["input"], z["output"], z["forward"]] for z in info["zones"]],
        )
        return 0

    if args.rcmd == "list":
        print_rules(router.ipv6_wan_rules(), args.json)
        return 0

    if args.rcmd == "add":
        name = args.name or f"omp-{args.address.exploded[-4:]}"
        if any(r.name == name for r in router.all_rules()):
            raise RouterError(f"a rule named {name!r} already exists")
        section = router.add_ipv6_allow(str(args.address), args.proto, args.port, name)
        created = next((r for r in router.ipv6_wan_rules() if r.section == section), None)
        if created is None:
            raise RouterError(f"uci returned section {section!r} but the rule is not listed")
        if args.json:
            print(json.dumps(rule_dict(created)))
        else:
            print(f"added {created.section} {created.name}: {created.proto} -> {created.dest_ip} port {created.dest_port or 'any'}")
        return 0

    if args.rcmd == "delete":
        rule = find_rule(router.ipv6_wan_rules(), args.rule)
        if rule.dest_ip and _is_protected(rule.dest_ip) and not args.i_know:
            raise RouterError(f"refusing to delete {rule.section} {rule.name!r}: it protects {PROTECTED_ADDRESS} (pass --i-know)")
        router.delete_rule(rule.section)
        if any(r.section == rule.section for r in router.all_rules()):
            raise RouterError(f"uci accepted the delete but {rule.section} is still listed")
        if args.json:
            print(json.dumps({"deleted": rule_dict(rule)}))
        else:
            print(f"deleted {rule.section} {rule.name}")
        return 0

    raise RouterError(f"unknown command {args.cmd} {args.rcmd}")


def _is_protected(dest_ip: str) -> bool:
    for part in dest_ip.split():
        try:
            net = ipaddress.ip_network(part.lstrip("!"), strict=False)
        except ValueError:
            continue
        if net.version == 6 and PROTECTED_ADDRESS in net:
            return True
    return False


def main() -> None:
    args = build_parser().parse_args()
    try:
        sys.exit(run(args))
    except RouterError as e:
        print(f"router-cm-beryl: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
