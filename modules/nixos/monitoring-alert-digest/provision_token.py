"""fleet-alert-digest-token: a Grafana Viewer service-account token for the
digest, created through Grafana's API (it can't provision service
accounts from files). Idempotent: every run checks the account is still
a Viewer (an admin may have changed it in the UI); if it isn't, the role
is patched back and the token rotated. A Viewer whose token still reads
both endpoints is left alone; otherwise the account is (re)created and
gets a fresh token.

Usage: fleet-alert-digest-token <token-file>
Admin credentials come from $CREDENTIALS_DIRECTORY (grafana-admin-username,
grafana-admin-password). The token is written 0600 and never printed.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GRAFANA = os.environ.get("DIGEST_GRAFANA_URL", "http://127.0.0.1:3000")
NAME = "fleet-alert-digest"
ROLE = "Viewer"
# The two endpoints the digest reads; a token that can read both is good.
PROBES = ("/api/prometheus/grafana/api/v1/alerts",
          "/api/annotations?type=alert&limit=1")
# Grafana's start: up to 5 min in all, each try bounded so a hanging
# connect can't stretch it.
WAIT_TOTAL = 300
WAIT_TRY_TIMEOUT = 5
WAIT_SLEEP = 3


def credential(name):
    with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], name)) as f:
        return f.read().strip()


def call(method, path, auth, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if auth:
        headers["Authorization"] = auth
    req = urllib.request.Request(GRAFANA + path, data=data, method=method,
                                 headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw else {}


def wait_for_grafana():
    deadline = time.monotonic() + WAIT_TOTAL
    while True:
        try:
            call("GET", "/api/health", None, timeout=WAIT_TRY_TIMEOUT)
            return
        except (OSError, urllib.error.URLError, ValueError):
            if time.monotonic() + WAIT_SLEEP >= deadline:
                break
            time.sleep(WAIT_SLEEP)
    sys.exit(f"fleet-alert-digest-token: Grafana not up after "
             f"{WAIT_TOTAL // 60} min")


def token_works(path):
    try:
        with open(path) as f:
            token = f.read().strip()
    except FileNotFoundError:
        return False
    if not token:
        return False
    try:
        for probe in PROBES:
            call("GET", probe, f"Bearer {token}")
        return True
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return False
        raise


def write_token(path, token):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token)
    os.replace(tmp, path)


def main():
    path = sys.argv[1]
    wait_for_grafana()
    admin = "Basic " + base64.b64encode(
        f"{credential('grafana-admin-username')}:"
        f"{credential('grafana-admin-password')}".encode()).decode()
    query = urllib.parse.urlencode({"query": NAME})
    found = call("GET", f"/api/serviceaccounts/search?{query}", admin)
    sa = next((s for s in found.get("serviceAccounts") or []
               if s.get("name") == NAME), None)
    if sa is None:
        sa = call("POST", "/api/serviceaccounts", admin,
                  {"name": NAME, "role": ROLE, "isDisabled": False})
        print(f"fleet-alert-digest-token: created service account {sa['id']}")
    elif sa.get("role") != ROLE or sa.get("isDisabled"):
        # Checked on every run, even with a working token: a token of an
        # account raised to Editor/Admin must not stay in use.
        call("PATCH", f"/api/serviceaccounts/{sa['id']}", admin,
             {"role": ROLE, "isDisabled": False})
        print(f"fleet-alert-digest-token: service account was "
              f"{sa.get('role')}{' (disabled)' if sa.get('isDisabled') else ''}, "
              f"set back to {ROLE}; rotating the token")
    elif token_works(path):
        print("fleet-alert-digest-token: Viewer, token valid, nothing to do")
        return
    # Old tokens are lost with the file (or came from a wrong role):
    # drop them, mint one.
    for t in call("GET", f"/api/serviceaccounts/{sa['id']}/tokens", admin) or []:
        call("DELETE", f"/api/serviceaccounts/{sa['id']}/tokens/{t['id']}", admin)
    new = call("POST", f"/api/serviceaccounts/{sa['id']}/tokens", admin,
               {"name": f"{NAME}-{int(time.time())}"})
    write_token(path, new["key"])
    if not token_works(path):
        sys.exit("fleet-alert-digest-token: new token can't read alerts")
    print("fleet-alert-digest-token: new token written")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        sys.exit(f"fleet-alert-digest-token: Grafana HTTP {e.code} on {e.url}")
