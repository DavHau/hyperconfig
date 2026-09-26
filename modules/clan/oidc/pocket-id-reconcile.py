"""Reconcile a Pocket ID instance with a declared state (groups, users, OIDC
clients, client secrets, branding images).

Environment:
  POCKET_ID_URL          base URL of the local pocket-id (http://127.0.0.1:1411)
  DESIRED_STATE          path to the JSON rendered by the clan service
  LOGO                   path to the PNG used as logo (light+dark) and favicon
  CREDENTIALS_DIRECTORY  systemd credentials: api_key, client-<id> (secret value)

Every step is read -> diff -> write and safe to re-run. Groups and clients
are fully declarative (absent ones are deleted); users are only ever
created/updated, never deleted (their passkeys cannot be reproduced).
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = os.environ["POCKET_ID_URL"].rstrip("/")
CREDS = os.environ["CREDENTIALS_DIRECTORY"]
SECRET_PREFIX_LENGTH = 4  # model.OidcClientSecretPrefixLength


def credential(name):
    with open(os.path.join(CREDS, name)) as f:
        return f.read().strip()


API_KEY = credential("api_key")


def log(msg):
    print(msg, flush=True)


def request(method, path, body=None, *, content_type="application/json"):
    data = None
    headers = {"X-API-Key": API_KEY, "Accept": "application/json"}
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        headers["Content-Type"] = content_type
    req = urllib.request.Request(f"{BASE}/api{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> {e.code}: {e.read().decode(errors='replace')}")
    return json.loads(raw) if raw else None


def list_all(path):
    """Drain a paginated collection (pocket-id caps pages at 100)."""
    items, page = [], 1
    while True:
        res = request("GET", f"{path}?pagination[page]={page}&pagination[limit]=100")
        items.extend(res["data"])
        if page >= res["pagination"]["totalPages"]:
            return items
        page += 1


def multipart(filename, payload, content_type):
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode() + payload + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def wait_healthy(seconds=60):
    deadline = time.monotonic() + seconds
    while True:
        try:
            with urllib.request.urlopen(f"{BASE}/healthz", timeout=5) as resp:
                if 200 <= resp.status < 300:  # pocket-id answers 204
                    return
        except (urllib.error.URLError, OSError):
            pass
        if time.monotonic() > deadline:
            sys.exit("pocket-id did not become healthy")
        time.sleep(1)


def reconcile_groups(desired):
    existing = {g["name"]: g for g in list_all("/user-groups")}
    for name in sorted(desired):
        if name not in existing:
            existing[name] = request("POST", "/user-groups", {"name": name, "friendlyName": name})
            log(f"created group {name}")
    for name, g in existing.items():
        if name not in desired:
            request("DELETE", f"/user-groups/{g['id']}")
            log(f"deleted group {name}")
    return {name: g["id"] for name, g in existing.items() if name in desired}


def reconcile_users(desired, group_ids):
    existing = {u["username"]: u for u in list_all("/users")}
    for username, spec in sorted(desired.items()):
        body = {
            "username": username,
            "email": spec["email"],
            "emailVerified": spec["email"] is not None,
            "firstName": spec["displayName"],
            "lastName": "",
            "displayName": spec["displayName"],
            "isAdmin": spec["admin"],
        }
        user = existing.get(username)
        if user is None:
            user = request("POST", "/users", body)
            log(f"created user {username}")
        elif any(user.get(k) != v for k, v in body.items() if k != "emailVerified"):
            body["disabled"] = user.get("disabled", False)
            body["locale"] = user.get("locale")
            request("PUT", f"/users/{user['id']}", body)
            log(f"updated user {username}")
        want = sorted(group_ids[g] for g in spec["groups"])
        have = sorted(g["id"] for g in user.get("userGroups") or [])
        if want != have:
            request("PUT", f"/users/{user['id']}/user-groups", {"userGroupIds": want})
            log(f"set groups of {username}: {', '.join(spec['groups']) or '-'}")
    for username in existing.keys() - desired.keys():
        if not username.startswith("static-api-user-"):
            log(f"leaving undeclared user {username} alone")


def reconcile_clients(desired, group_ids):
    existing = {c["id"]: c for c in list_all("/oidc/clients")}
    for client_id, spec in sorted(desired.items()):
        body = {
            "name": spec["name"],
            "callbackURLs": spec["callbackURLs"],
            "logoutCallbackURLs": spec["logoutCallbackURLs"],
            "isPublic": spec["public"],
            "pkceEnabled": spec["pkce"],
            "skipConsent": True,
            "requiresReauthentication": False,
            "requiresPushedAuthorizationRequests": False,
            # Without this pocket-id ignores allowedUserGroups (anyone may
            # sign in) and an update clears them. Every client declares groups.
            "isGroupRestricted": True,
        }
        if client_id not in existing:
            request("POST", "/oidc/clients", {"id": client_id, **body})
            log(f"created client {client_id}")
        # The list endpoint carries neither URLs nor allowed groups; diff the full record.
        client = request("GET", f"/oidc/clients/{client_id}")
        if any(client.get(k) != v for k, v in body.items()):
            request("PUT", f"/oidc/clients/{client_id}", body)
            log(f"updated client {client_id}")
        want = sorted(group_ids[g] for g in spec["allowedGroups"])
        have = sorted(g["id"] for g in client.get("allowedUserGroups") or [])
        if want != have:
            request("PUT", f"/oidc/clients/{client_id}/allowed-user-groups", {"userGroupIds": want})
            log(f"set allowed groups of {client_id}: {', '.join(spec['allowedGroups'])}")
        if not spec["public"]:
            reconcile_secret(client_id)
    for client_id in existing.keys() - desired.keys():
        request("DELETE", f"/oidc/clients/{client_id}")
        log(f"deleted client {client_id}")


def reconcile_secret(client_id):
    """The clan var is the one live secret: keep the entry whose clear-text
    prefix matches ours, create it if missing, drop every other secret."""
    value = credential(f"client-{client_id}")
    secrets = request("GET", f"/oidc/clients/{client_id}/secrets") or []
    keep = next((s for s in secrets if s["prefix"] == value[:SECRET_PREFIX_LENGTH]), None)
    if keep is None:
        keep = request("POST", f"/oidc/clients/{client_id}/secrets", {"secret": value})
        log(f"installed secret for {client_id}")
    for s in secrets:
        if s["id"] != keep["id"]:
            request("DELETE", f"/oidc/clients/{client_id}/secrets/{s['id']}")
            log(f"removed stale secret {s['prefix']}… of {client_id}")


def reconcile_images(logo_path):
    with open(logo_path, "rb") as f:
        payload = f.read()
    body, content_type = multipart("logo.png", payload, "image/png")
    for path in ("/application-images/logo?light=true", "/application-images/logo?light=false", "/application-images/favicon"):
        request("PUT", path, body, content_type=content_type)
    log("uploaded logo and favicon")


def main():
    with open(os.environ["DESIRED_STATE"]) as f:
        state = json.load(f)
    wait_healthy()
    group_ids = reconcile_groups(set(state["groups"]))
    reconcile_users(state["users"], group_ids)
    reconcile_clients(state["clients"], group_ids)
    reconcile_images(os.environ["LOGO"])
    log("reconciled")


if __name__ == "__main__":
    main()
