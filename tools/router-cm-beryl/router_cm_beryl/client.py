"""ssh + uci transport for the GL.iNet Beryl (OpenWrt, fw3). See PROTOCOL.md."""

import json
import os
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path

PROTOS = ("all", "tcp", "udp", "tcpudp")
PORT_PROTOS = ("tcp", "udp", "tcpudp")
FIREWALL_RELOAD = "/etc/init.d/firewall reload"


class RouterError(Exception):
    pass


@dataclass(frozen=True)
class Rule:
    section: str  # uci section id (named or cfgXXXXXX)
    index: int  # position among all firewall sections
    name: str
    enabled: bool
    src: str
    dest: str
    family: str
    dest_ip: str
    proto: str
    dest_port: str
    target: str


def known_hosts_path() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "router-cm-beryl" / "known_hosts"


class Router:
    """Runs shell commands on the router as root over ssh with password auth (sshpass)."""

    def __init__(self, host: str, password: str, jump: str | None = None, log=lambda m: None):
        self.host = host
        self.password = password
        self.jump = jump
        self.log = log

    def run(self, command: str, timeout: float = 60) -> str:
        kh = known_hosts_path()
        kh.parent.mkdir(parents=True, exist_ok=True)
        argv = [
            "sshpass",
            "-e",
            "ssh",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={kh}",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if self.jump:
            argv += ["-J", self.jump]
        argv += [f"root@{self.host}", command]
        self.log(f"ssh {self.host}: {command}")
        env = dict(os.environ, SSHPASS=self.password)
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
        except FileNotFoundError as e:
            raise RouterError(f"{e.filename} not found on PATH") from None
        except subprocess.TimeoutExpired:
            raise RouterError(f"ssh to {self.host} timed out after {timeout}s") from None
        if proc.returncode != 0:
            err = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
            if proc.returncode == 5 or "Permission denied" in err:
                err = f"{err} (wrong password?)"
            raise RouterError(f"ssh {self.host}: {err}")
        return proc.stdout

    def ubus(self, path: str, method: str, params: dict | None = None) -> dict:
        cmd = f"ubus call {path} {method}"
        if params:
            cmd += " " + shlex.quote(json.dumps(params))
        out = self.run(cmd)
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            raise RouterError(f"unexpected ubus output: {out.strip()[:200]}") from None

    # --- device facts -------------------------------------------------------

    def board(self) -> dict:
        return self.ubus("system", "board")

    def gl_version(self) -> str:
        return self.run("cat /etc/glversion 2>/dev/null || true").strip()

    def firewall_flavour(self) -> str:
        out = self.run("if [ -x /sbin/fw4 ]; then echo fw4; elif [ -x /sbin/fw3 ]; then echo fw3; else echo unknown; fi")
        return out.strip()

    def zones(self) -> list[dict]:
        vals = self.ubus("uci", "get", {"config": "firewall", "type": "zone"})["values"]
        zones = sorted(vals.values(), key=lambda s: s[".index"])
        return [
            {
                "name": z.get("name", z[".name"]),
                "network": _as_list(z.get("network")),
                "input": z.get("input", ""),
                "output": z.get("output", ""),
                "forward": z.get("forward", ""),
            }
            for z in zones
        ]

    # --- rules --------------------------------------------------------------

    def all_rules(self) -> list[Rule]:
        vals = self.ubus("uci", "get", {"config": "firewall", "type": "rule"})["values"]
        rules = [
            Rule(
                section=s[".name"],
                index=s[".index"],
                name=s.get("name", ""),
                enabled=s.get("enabled", "1") not in ("0", "false", "no", "off"),
                src=s.get("src", ""),
                dest=s.get("dest", ""),
                family=s.get("family", "any"),
                dest_ip=" ".join(_as_list(s.get("dest_ip"))),
                proto=" ".join(_as_list(s.get("proto") or s.get("dest_proto"))) or "any",
                dest_port=" ".join(_as_list(s.get("dest_port"))),
                target=s.get("target", "DROP"),
            )
            for s in vals.values()
        ]
        return sorted(rules, key=lambda r: r.index)

    def ipv6_wan_rules(self) -> list[Rule]:
        """Rules that can match inbound IPv6 from the wan zone (family ipv6 or any)."""
        return [r for r in self.all_rules() if r.src == "wan" and r.family in ("ipv6", "any")]

    def add_ipv6_allow(self, address: str, proto: str, port: str | None, name: str) -> str:
        """Append an anonymous `config rule` section, commit and reload. Returns the section id.

        `proto="all"` is written explicitly: fw3 treats a missing `proto` as tcp+udp.
        """
        if proto not in PROTOS:
            raise RouterError(f"unsupported proto {proto!r}")
        if port and proto not in PORT_PROTOS:
            raise RouterError("a port needs proto tcp, udp or tcpudp")
        opts = {
            "name": name,
            "src": "wan",
            "dest": "lan",
            "family": "ipv6",
            "proto": proto,
            "dest_ip": address,
            "target": "ACCEPT",
        }
        if port:
            opts["dest_port"] = port
        sets = "; ".join(f"uci set firewall.$id.{k}={shlex.quote(v)}" for k, v in opts.items())
        script = (
            "id=$(uci add firewall rule) || exit 2; "
            f"{{ {sets}; }} || {{ uci revert firewall; exit 3; }}; "
            "uci commit firewall || exit 4; "
            f"{FIREWALL_RELOAD} >/dev/null 2>&1 || exit 5; "
            'echo "$id"'
        )
        out = self.run(script, timeout=120)
        section = out.strip().splitlines()[-1] if out.strip() else ""
        if not section:
            raise RouterError("uci add returned no section id")
        return section

    def delete_rule(self, section: str) -> None:
        script = (
            f"uci get firewall.{shlex.quote(section)} >/dev/null || exit 2; "
            f"uci delete firewall.{shlex.quote(section)} || exit 3; "
            "uci commit firewall || exit 4; "
            f"{FIREWALL_RELOAD} >/dev/null 2>&1 || exit 5"
        )
        self.run(script, timeout=120)


def _as_list(v) -> list[str]:
    if v is None:
        return []
    if isinstance(v, list):
        return [str(x) for x in v]
    return [str(v)]
