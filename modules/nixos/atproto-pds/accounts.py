"""atproto-pds-accounts: create the PDS's declared accounts, apply their
password vars (./default.nix has the why).

argv[1]: JSON config (url, unit, self, stateDir, database, dbUser, accounts:
[{name, handle, email, did}]). Each account's password is the systemd
credential <name>. Runs as root after tranquil-pds.service.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

import bcrypt

cfg = json.load(open(sys.argv[1]))
url = cfg["url"]
creds = os.environ["CREDENTIALS_DIRECTORY"]


def log(msg):
    print(msg, flush=True)


def xrpc(method, body=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"{url}/xrpc/{method}",
        data=data,
        headers={"Content-Type": "application/json"} if data else {},
        method="POST" if data else "GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw.decode(errors="replace")}


def wait_healthy(deadline=180):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(f"{url}/xrpc/_health", timeout=5) as r:
                if r.status == 200:
                    return
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(1)
    sys.exit(f"{url} not healthy after {deadline}s")


def psql(sql, **params):
    """Run sql as the PDS's database user (peer auth), params as psql
    variables (:'name' in sql quotes them), set on stdin, never in argv
    (every uid on the host reads /proc/*/cmdline)."""
    args = ["runuser", "-u", cfg["dbUser"], "--", "psql", "-d", cfg["database"],
            "-v", "ON_ERROR_STOP=1", "-tAq"]
    pre = ""
    for k, v in params.items():
        # DIDs and bcrypt hashes only: nothing \set would read as a quote,
        # a backslash or another variable.
        if not re.fullmatch(r"[A-Za-z0-9.:$/_-]+", v):
            sys.exit(f"psql param {k}: unexpected characters")
        pre += f"\\set {k} '{v}'\n"
    return subprocess.run(args, input=pre + sql, text=True, check=True,
                          capture_output=True).stdout.strip()


def exists(did):
    return psql("SELECT count(*) FROM users WHERE did = :'did';\n", did=did) == "1"


def bootstrap_code():
    """The invite code tranquil logged at this start (only when it has no
    users); this invocation's journal only."""
    inv = subprocess.run(
        ["systemctl", "show", "-P", "InvocationID", cfg["unit"]],
        text=True, check=True, capture_output=True).stdout.strip()
    end = time.monotonic() + 60
    while time.monotonic() < end:
        out = subprocess.run(
            ["journalctl", "-o", "cat", "--no-pager", f"_SYSTEMD_INVOCATION_ID={inv}"],
            text=True, capture_output=True).stdout
        m = re.search(r"Bootstrap invite code: ([A-Za-z0-9-]+)", re.sub(r"\x1b\[[0-9;]*m", "", out))
        if m:
            return m.group(1)
        time.sleep(1)
    return None


def marker_path(name):
    return os.path.join(cfg["stateDir"], f"{name}.applied")


def secret(password):
    """The bytes bcrypt hashes: the first 72, as the Rust bcrypt crate
    tranquil uses truncates (Python's bcrypt raises on longer input)."""
    return password.encode()[:72]


def applied(name, password):
    try:
        h = open(marker_path(name), "rb").read().strip()
    except FileNotFoundError:
        return False
    try:
        return bcrypt.checkpw(secret(password), h)
    except ValueError:
        return False


def mark(name, password):
    tmp = marker_path(name) + ".tmp"
    with open(tmp, "wb") as f:
        f.write(bcrypt.hashpw(secret(password), bcrypt.gensalt()))
    os.replace(tmp, marker_path(name))


def main():
    wait_healthy()
    failed = False
    revoked = False
    for a in cfg["accounts"]:
        name, did = a["name"], a["did"]
        password = open(os.path.join(creds, name)).read().strip()
        if not exists(did):
            code = bootstrap_code()
            if code is None:
                # Only an empty PDS logs one; another account was made first.
                log(f"{name}: {did} missing and no bootstrap invite code (the PDS has users already)")
                failed = True
                continue
            status, body = xrpc("com.atproto.server.createAccount", {
                "handle": a["handle"],
                "email": a["email"],
                "password": password,
                "inviteCode": code,
                "didType": "web",
            })
            if status != 200 or body.get("did") != did:
                log(f"{name}: createAccount failed: {status} {body.get('error')} {body.get('message')}")
                failed = True
                continue
            mark(name, password)
            log(f"{name}: created {did}")
            continue
        if applied(name, password):
            log(f"{name}: {did} unchanged")
            continue
        h = bcrypt.hashpw(secret(password), bcrypt.gensalt(12)).decode()
        # A changed var may be a leaked password's rotation: cut every way
        # in made with the old one too (sessions, OAuth grants, remembered
        # OAuth devices, which sign in again without the password, pending
        # authorizations, app passwords), more than tranquil's own reset
        # (sessions only). Passkeys and TOTP stay: they are the owner's.
        n = psql("BEGIN;\n"
                 "DELETE FROM session_tokens WHERE did = :'did';\n"
                 "DELETE FROM oauth_token WHERE did = :'did';\n"
                 "DELETE FROM oauth_account_device WHERE did = :'did';\n"
                 "DELETE FROM oauth_authorization_request WHERE did = :'did';\n"
                 "DELETE FROM app_passwords WHERE user_id = (SELECT id FROM users WHERE did = :'did');\n"
                 "WITH u AS (UPDATE users SET password_hash = :'hash' WHERE did = :'did' RETURNING 1)"
                 " SELECT count(*) FROM u;\n"
                 "COMMIT;\n", hash=h, did=did)
        if n != "1":
            log(f"{name}: password update matched {n} rows")
            failed = True
            continue
        mark(name, password)
        revoked = True
        log(f"{name}: password applied to {did}, its sessions, OAuth tokens and devices and app passwords revoked")
    if revoked:
        # tranquil caches a session as valid for 60 s (ripple, in memory):
        # a restart drops that. It restarts this unit too (Requires=), so
        # not from in here (that would cancel this run): a transient unit
        # ordered after this one does it; the rerun finds every var applied.
        log(f"restarting {cfg['unit']} to drop its session cache")
        subprocess.run(["systemd-run", "--no-block", "--collect", "--quiet",
                        "-p", f"After={cfg['self']}",
                        "systemctl", "restart", cfg["unit"]], check=True)
    sys.exit(1 if failed else 0)


main()
