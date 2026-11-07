"""home-assistant-apply [--dry-run] [--skip-token] [HOST ...]

Converges Roman's Home Assistant instances to ./hosts.nix (default: all):
ships ./remote.py over ssh to each instance's SSH add-on and runs it there
with that host's declared state. A user's long-lived token is minted only
when its clan var is absent or HA rejects it (GET /api/), then stored with
`clan vars set` (run from the repo root; clan comes from the devshell).
Tokens never reach the terminal.
"""

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

REMOTE_PATH = "/tmp/hyperconfig-home-assistant-apply.py"


class Failed(Exception):
    pass


def api_url(address):
    host = f"[{address}]" if ":" in address else address
    return f"http://{host}:8123/api/"


def token_valid(address, token):
    req = urllib.request.Request(api_url(address), headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return False
        raise


def needs_mint(host, state, name, spec):
    got = subprocess.run(
        ["clan", "vars", "get", spec["machine"], spec["var"]],
        capture_output=True,
        text=True,
        check=False,
    )
    if got.returncode != 0:
        if "has not been generated yet" in got.stderr:
            print(f"{host}: {spec['machine']} var {spec['var']} absent", file=sys.stderr)
            return True
        raise Failed(f"{host}: clan vars get {spec['machine']} {spec['var']}: {got.stderr.strip()}")
    if token_valid(state["address"], got.stdout.strip()):
        return False
    print(f"{host}: token of {name} in {spec['var']} is rejected", file=sys.stderr)
    return True


def ssh(state, command, **kwargs):
    return subprocess.run(
        [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=20",
            "-p", str(state["sshPort"]),
            f"root@{state['address']}",
            command,
        ],
        check=False,
        **kwargs,
    )


def apply(host, state, remote, dry_run, skip_token):
    mint = []
    if not skip_token:
        mint = [
            name
            for name, user in state["users"].items()
            if "token" in user and needs_mint(host, state, name, user["token"])
        ]
    with open(remote, "rb") as script:
        if ssh(state, f"cat > {REMOTE_PATH}", stdin=script).returncode != 0:
            raise Failed(f"{host}: cannot ssh to root@{state['address']}")
    request = json.dumps({"state": state, "dryRun": dry_run, "mint": mint})
    ran = ssh(
        state,
        f"python3 {REMOTE_PATH}; rc=$?; rm -f {REMOTE_PATH}; exit $rc",
        input=request,
        stdout=subprocess.PIPE,
        text=True,
    )
    if ran.returncode != 0:
        raise Failed(f"{host}: remote apply failed ({ran.returncode})")
    result = json.loads(ran.stdout)
    for name, token in result["tokens"].items():
        spec = state["users"][name]["token"]
        if not token_valid(state["address"], token):
            raise Failed(f"{host}: the token minted for {name} is rejected by {api_url(state['address'])}")
        subprocess.run(["clan", "vars", "set", spec["machine"], spec["var"]], input=token, text=True, check=True)
        print(f"{host}: stored the token of {name} in {spec['machine']} var {spec['var']}", file=sys.stderr)
    n = len(result["changes"])
    verb = "would make" if dry_run else "made"
    print(f"{host}: {verb} {n} change(s)" if n else f"{host}: no changes")


def main():
    parser = argparse.ArgumentParser(prog="home-assistant-apply", description=__doc__.split("\n\n")[1])
    parser.add_argument("--state", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--remote", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true", help="report what would change, change nothing")
    parser.add_argument("--skip-token", action="store_true", help="neither check nor mint tokens")
    parser.add_argument("hosts", nargs="*", metavar="HOST")
    args = parser.parse_args()
    with open(args.state) as f:
        hosts = json.load(f)
    unknown = sorted(set(args.hosts) - set(hosts))
    if unknown:
        parser.error(f"unknown host(s) {', '.join(unknown)}; known: {', '.join(sorted(hosts))}")
    failed = False
    for host in args.hosts or sorted(hosts):
        try:
            apply(host, hosts[host], args.remote, args.dry_run, args.skip_token)
        except Failed as e:
            print(f"error: {e}", file=sys.stderr)
            failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
