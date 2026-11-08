"""home-assistant-apply [--dry-run] [--skip-token] [--ssh-port PORT HOST] [HOST ...]

Converges Roman's Home Assistant instances to ./hosts.nix (default: all):
ships ./remote.py over ssh to each instance's SSH add-on and runs it there
with that host's declared state. A user's long-lived token is minted only
when its clan var is absent or HA rejects it (GET /api/), then stored with
`clan vars set` (run from the repo root). Tokens never reach the terminal.
A failing host does not stop the others; the exit status is 1 if any failed
or still needs a rerun.

Moving an instance off the official core_ssh add-on (see remote.py) takes
two runs: the first one starts the replacement on a temporary port and
says which; rerun that host with --ssh-port set to it.

patchedIntegrations (hosts.nix) are built here, for the HA version the
instance runs: that version's built-in integration, taken from its
homeassistant wheel on PyPI (sha256-checked against PyPI, cached; it, unlike
the git tag, carries the generated translations a custom component needs),
plus the patch and a manifest "version". remote.py installs the result as a
custom component where a config entry of that domain exists. A patch that
neither applies nor reverse-applies fails the host (the override is removed,
not installed); one that reverse-applies means the running HA carries the
fix, so the override is removed.
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

REMOTE_PATH = "/tmp/hyperconfig-home-assistant-apply.py"
WHEEL_CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "hyperconfig", "home-assistant-wheels"
)


class Failed(Exception):
    pass


def api_url(address):
    host = f"[{address}]" if ":" in address else address
    return f"http://{host}:8123/api/"


def token_valid(address, token):
    url = api_url(address)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return False
        raise Failed(f"GET {url}: {e.code} {e.reason}") from None
    except OSError as e:  # URLError, timeouts, refused connections
        raise Failed(f"GET {url}: {e}") from None


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
        raise Failed(f"clan vars get {spec['machine']} {spec['var']}: {got.stderr.strip()}")
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


def remote_run(state, request, keep=False):
    """Run the shipped remote.py with `request`; remove it unless `keep`."""
    rm = "" if keep else f"; rm -f {REMOTE_PATH}"
    ran = ssh(
        state,
        f"python3 {REMOTE_PATH}; rc=$?{rm}; exit $rc",
        input=json.dumps(request),
        stdout=subprocess.PIPE,
        text=True,
    )
    if ran.returncode != 0:
        raise Failed(f"remote apply failed ({ran.returncode})")
    return json.loads(ran.stdout)


def wheel(version):
    """Path of the homeassistant wheel of `version`, fetched once, sha256 as PyPI lists it."""
    path = os.path.join(WHEEL_CACHE, f"homeassistant-{version}-py3-none-any.whl")
    if os.path.exists(path):
        return path
    url = f"https://pypi.org/pypi/homeassistant/{version}/json"
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            release = json.load(resp)
    except urllib.error.HTTPError as e:
        raise Failed(f"GET {url}: {e.code} {e.reason}") from None
    wheels = [f for f in release["urls"] if f["filename"] == os.path.basename(path)]
    if len(wheels) != 1:
        raise Failed(f"PyPI lists no {os.path.basename(path)}")
    os.makedirs(WHEEL_CACHE, exist_ok=True)
    part = path + ".part"
    digest = hashlib.sha256()
    print(f"fetching {wheels[0]['url']}", file=sys.stderr)
    with urllib.request.urlopen(wheels[0]["url"], timeout=600) as resp, open(part, "wb") as out:
        while chunk := resp.read(1 << 20):
            digest.update(chunk)
            out.write(chunk)
    if digest.hexdigest() != wheels[0]["digests"]["sha256"]:
        os.remove(part)
        raise Failed(f"{wheels[0]['url']}: sha256 differs from PyPI's")
    os.replace(part, path)
    return path


def build(domain, spec, version):
    """The patched integration for remote.py: {"files": {path: base64}, ...} or {"remove": why}.

    Raises Failed when the patch neither applies nor reverse-applies.
    """
    prefix = f"homeassistant/components/{domain}/"
    name = os.path.basename(spec["patch"])
    with open(spec["patch"], "rb") as f:
        patch_sha256 = hashlib.sha256(f.read()).hexdigest()
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(wheel(version)) as whl:
            members = [m for m in whl.namelist() if m.startswith(prefix) and not m.endswith("/")]
            if not members:
                raise Failed(f"homeassistant {version} has no integration {domain}")
            for m in members:
                whl.extract(m, tmp)

        def git_apply(*args):
            # Outside any repository, so the patch's paths resolve against tmp.
            return subprocess.run(
                ["git", "apply", *args, spec["patch"]],
                cwd=tmp,
                env=dict(os.environ, GIT_CEILING_DIRECTORIES=os.path.dirname(tmp)),
                capture_output=True,
                text=True,
                check=False,
            )

        if git_apply("--check").returncode != 0:
            if git_apply("--check", "--reverse").returncode == 0:
                return {"haVersion": version, "remove": f"homeassistant {version} already carries {name}"}
            raise Failed(f"{name} does not apply to homeassistant {version}: {git_apply('--check').stderr.strip()}")
        applied = git_apply()
        if applied.returncode != 0:
            raise Failed(f"{name}: {applied.stderr.strip()}")
        files = {}
        for m in members:
            with open(os.path.join(tmp, m), "rb") as f:
                files[m[len(prefix):]] = f.read()
    # Custom components need a version; the HA one says what it was built from.
    manifest = json.loads(files["manifest.json"])
    manifest["version"] = version
    files["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return {
        "haVersion": version,
        "patch": f"{name} {patch_sha256}",
        "files": {path: base64.b64encode(data).decode() for path, data in files.items()},
    }


def patched_integrations(host, state):
    """Build the declared patched integrations; return (request part, errors)."""
    wanted = state.get("patchedIntegrations") or {}
    if not wanted:
        return {}, []
    found = remote_run(state, {"probe": sorted(wanted)}, keep=True)
    version = found["haVersion"]
    integrations, errors = {}, []
    for domain, spec in wanted.items():
        if not found["configured"][domain]:
            integrations[domain] = {"haVersion": version, "remove": f"no {domain} config entry"}
            continue
        try:
            integrations[domain] = build(domain, spec, version)
        except Failed as e:
            print(f"{host}: patched {domain}: {e}", file=sys.stderr)
            integrations[domain] = {"haVersion": version, "remove": f"its patch does not fit HA {version}"}
            errors.append(f"patched {domain}: {e}")
    return integrations, errors


def apply(host, state, remote, dry_run, skip_token):
    """Converge one host; return False when it needs a rerun."""
    mint = []
    if not skip_token:
        mint = [
            name
            for name, user in state["users"].items()
            if "token" in user and needs_mint(host, state, name, user["token"])
        ]
    with open(remote, "rb") as script:
        if ssh(state, f"cat > {REMOTE_PATH}", stdin=script).returncode != 0:
            raise Failed(f"cannot ssh to root@{state['address']} -p {state['sshPort']}")
    try:
        integrations, errors = patched_integrations(host, state)
    except BaseException:
        ssh(state, f"rm -f {REMOTE_PATH}")
        raise
    result = remote_run(state, {"state": state, "dryRun": dry_run, "mint": mint, "integrations": integrations})
    for name, token in result["tokens"].items():
        spec = state["users"][name]["token"]
        if not token_valid(state["address"], token):
            raise Failed(f"the token minted for {name} is rejected by {api_url(state['address'])}")
        subprocess.run(["clan", "vars", "set", spec["machine"], spec["var"]], input=token, text=True, check=True)
        print(f"{host}: stored the token of {name} in {spec['machine']} var {spec['var']}", file=sys.stderr)
    n = len(result["changes"])
    verb = "would make" if dry_run else "made"
    print(f"{host}: {verb} {n} change(s)" if n else f"{host}: no changes")
    if errors:
        raise Failed("; ".join(errors))
    port = result.get("rerunSshPort")
    if port is not None:
        print(
            f"{host}: the session runs in an add-on that is to be replaced; rerun through the"
            f" replacement: home-assistant-apply --ssh-port {port} {host}",
            file=sys.stderr,
        )
        return False
    return True


def main():
    parser = argparse.ArgumentParser(prog="home-assistant-apply", description=__doc__.split("\n\n")[1])
    parser.add_argument("--state", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--remote", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true", help="report what would change, change nothing")
    parser.add_argument("--skip-token", action="store_true", help="neither check nor mint tokens")
    parser.add_argument(
        "--ssh-port", type=int, help="ssh to this port instead of the declared one (one HOST; see remote.py)"
    )
    parser.add_argument("hosts", nargs="*", metavar="HOST")
    args = parser.parse_args()
    with open(args.state) as f:
        hosts = json.load(f)
    unknown = sorted(set(args.hosts) - set(hosts))
    if unknown:
        parser.error(f"unknown host(s) {', '.join(unknown)}; known: {', '.join(sorted(hosts))}")
    if args.ssh_port is not None:
        if len(args.hosts) != 1:
            parser.error("--ssh-port needs exactly one HOST")
        hosts[args.hosts[0]]["sshPort"] = args.ssh_port
    failed = False
    for host in args.hosts or sorted(hosts):
        try:
            if not apply(host, hosts[host], args.remote, args.dry_run, args.skip_token):
                failed = True
        except (Failed, OSError, subprocess.CalledProcessError, ValueError) as e:
            print(f"error: {host}: {e}", file=sys.stderr)
            failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
