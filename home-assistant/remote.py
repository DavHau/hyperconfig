"""Converge one Home Assistant OS instance to its declared state.

Runs with python3 (stdlib only) inside the SSH add-on, which holds the
Supervisor token. Reads one JSON object on stdin:

    {"state": <one host of hosts.nix>, "dryRun": bool, "mint": [user names]}

Reports each change on stderr ("would" in a dry run) and prints one JSON
object on stdout for apply.py: {"changes": [...], "tokens": {user: token}}.
Tokens are never written anywhere else.

Official APIs only: Supervisor REST (add-ons, backups), Core REST via the
Supervisor proxy (config entries), Core websocket via the Supervisor proxy
(users, credentials), and Core's own login flow plus the user's websocket
to mint the long-lived token.
"""

import base64
import http.client
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SUPERVISOR = "http://supervisor"
TOKEN = os.environ["SUPERVISOR_TOKEN"]


class ApplyError(Exception):
    pass


def http(method, url, body=None, token=TOKEN, form=False, timeout=600):
    headers = {}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise ApplyError(f"{method} {url}: {e.code} {e.read()[:500]!r}") from None
    return json.loads(raw) if raw else None


def supervisor(method, path, body=None):
    reply = http(method, SUPERVISOR + path, body)
    if reply.get("result") != "ok":
        raise ApplyError(f"{method} {path}: {reply}")
    return reply.get("data")


def core(method, path, body=None):
    return http(method, f"{SUPERVISOR}/core/api{path}", body)


class WebSocket:
    """Minimal RFC 6455 client: text frames, client masking, pings."""

    def __init__(self, url):
        parts = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection(
            (parts.hostname, parts.port or 80), timeout=120
        )
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        self.sock.sendall(
            (
                f"GET {parts.path} HTTP/1.1\r\nHost: {parts.netloc}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ApplyError(f"websocket {url}: closed during handshake")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ApplyError(f"websocket {url}: {head.splitlines()[0]!r}")
        self.next_id = 1

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ApplyError("websocket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 1 << 16:
            header += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = secrets.token_bytes(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send(self, obj):
        self._send_frame(0x1, json.dumps(obj).encode())

    def recv(self):
        message = b""
        while True:
            b0, b1 = self._read(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                (n,) = struct.unpack("!H", self._read(2))
            elif n == 127:
                (n,) = struct.unpack("!Q", self._read(8))
            payload = self._read(n)
            if opcode == 0x8:
                raise ApplyError("websocket closed by server")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            message += payload
            if b0 & 0x80:
                return json.loads(message)

    def auth(self, token):
        hello = self.recv()
        if hello.get("type") != "auth_required":
            raise ApplyError(f"websocket: unexpected {hello}")
        self.send({"type": "auth", "access_token": token})
        reply = self.recv()
        if reply.get("type") != "auth_ok":
            raise ApplyError(f"websocket auth: {reply.get('type')}")
        return self

    def call(self, type_, **fields):
        msg_id = self.next_id
        self.next_id += 1
        self.send({"id": msg_id, "type": type_, **fields})
        while True:
            reply = self.recv()
            if reply.get("id") != msg_id or reply.get("type") != "result":
                continue
            if not reply.get("success"):
                raise ApplyError(f"{type_}: {reply.get('error')}")
            return reply.get("result")

    def close(self):
        self.sock.close()


class Run:
    def __init__(self, state, dry_run):
        self.state = state
        self.dry_run = dry_run
        self.changes = []
        self.backup_done = False
        self._admin_ws = None

    def change(self, what):
        self.changes.append(what)
        print(("would: " if self.dry_run else "change: ") + what, file=sys.stderr)
        return not self.dry_run

    def core_change(self, what):
        """Record a change of HA Core state, after backing Core up once."""
        if not self.change(what):
            return False
        if not self.backup_done:
            name = "hyperconfig-apply-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
            print(f"backup: {name} (homeassistant, partial)", file=sys.stderr)
            supervisor(
                "POST",
                "/backups/new/partial",
                {
                    "name": name,
                    "homeassistant": True,
                    "homeassistant_exclude_database": True,
                },
            )
            self.backup_done = True
        return True

    @property
    def admin_ws(self):
        if self._admin_ws is None:
            self._admin_ws = WebSocket("ws://supervisor/core/websocket").auth(TOKEN)
        return self._admin_ws

    # Supervisor: add-ons -------------------------------------------------

    def addons(self):
        self_slug = supervisor("GET", "/addons/self/info")["slug"]
        installed = {a["slug"] for a in supervisor("GET", "/addons")["addons"]}
        deferred = None
        for slug, want in self.state["addons"].items():
            if not want["present"]:
                if slug in installed:
                    if slug == self_slug:
                        raise ApplyError(f"{slug}: refusing to uninstall the add-on of this session")
                    if self.change(f"uninstall add-on {slug}"):
                        supervisor("POST", f"/addons/{slug}/uninstall")
                continue
            if slug not in installed:
                repos = {r["source"] for r in supervisor("GET", "/store/repositories")}
                if want["repository"] not in repos and self.change(
                    f"add add-on repository {want['repository']}"
                ):
                    supervisor("POST", "/store/repositories", {"repository": want["repository"]})
                if not self.change(f"install add-on {slug}"):
                    self.change(f"configure and start add-on {slug}")
                    continue
                supervisor("POST", f"/store/addons/{slug}/install")
            info = supervisor("GET", f"/addons/{slug}/info")
            body = {}
            for key in ("boot", "network", "options"):
                if info.get(key) != want[key]:
                    body[key] = want[key]
            if slug == self_slug:
                deferred = (slug, body)
                continue
            if body and self.change(f"set add-on {slug} {', '.join(sorted(body))}"):
                supervisor("POST", f"/addons/{slug}/options", body)
                if info["state"] == "started" and self.change(f"restart add-on {slug}"):
                    supervisor("POST", f"/addons/{slug}/restart")
                    info["state"] = "started"
            if want["started"] and info["state"] != "started" and self.change(f"start add-on {slug}"):
                supervisor("POST", f"/addons/{slug}/start")
        return deferred

    def self_addon(self, slug, body):
        """Change the session's own add-on, then restart it detached."""
        if not body or not self.change(
            f"set add-on {slug} {', '.join(sorted(body))} and restart it (drops this session)"
        ):
            return
        supervisor("POST", f"/addons/{slug}/options", body)
        # The restart kills this container, this script and its ssh session:
        # leave it to a detached process, after the result has been printed.
        subprocess.Popen(
            [
                "sh",
                "-c",
                (
                    'sleep 2; curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" '
                    f"{SUPERVISOR}/addons/{slug}/restart"
                ),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    # Core: users -----------------------------------------------------------

    def find_user(self, name):
        users = self.admin_ws.call("config/auth/list")
        found = [u for u in users if u["name"] == name and not u["system_generated"]]
        if len(found) > 1:
            raise ApplyError(f"user {name}: {len(found)} users carry that name")
        return found[0] if found else None

    def users(self):
        """Converge users; return {name: user_id or None (dry run)}."""
        ids = {}
        for name, want in self.state["users"].items():
            user = self.find_user(name)
            if user is None:
                if self.core_change(f"create user {name}"):
                    user = self.admin_ws.call(
                        "config/auth/create",
                        name=name,
                        group_ids=want["group_ids"],
                        local_only=want["local_only"],
                    )["user"]
                else:
                    ids[name] = None
                    continue
            fields = {
                k: want[k]
                for k in ("group_ids", "local_only", "is_active")
                if user[k] != want[k]
            }
            if fields and self.core_change(f"update user {name}: {', '.join(sorted(fields))}"):
                self.admin_ws.call("config/auth/update", user_id=user["id"], **fields)
            # Token-only user: no password login.
            if user["username"] is not None and self.core_change(
                f"remove password login {user['username']} of user {name}"
            ):
                self.admin_ws.call(
                    "config/auth_provider/homeassistant/delete", username=user["username"]
                )
            ids[name] = user["id"]
        return ids

    def mint(self, name, user_id):
        """Mint the user's long-lived token through a throwaway password.

        Changing another user's password is owner-only, which the
        Supervisor's user is not; an admin may add credentials to a user
        without any, and delete them. Deleting them also ends the login
        session made with them; the long-lived token is not bound to them.
        """
        token_spec = self.state["users"][name]["token"]
        if not self.core_change(f"mint long-lived token '{token_spec['clientName']}' for user {name}"):
            return None
        core_url = self.state["coreUrl"]
        client_id = core_url + "/"
        username = name
        password = secrets.token_urlsafe(32)
        self.admin_ws.call(
            "config/auth_provider/homeassistant/create",
            user_id=user_id,
            username=username,
            password=password,
        )
        try:
            flow = http(
                "POST",
                core_url + "/auth/login_flow",
                {"client_id": client_id, "handler": ["homeassistant", None], "redirect_uri": client_id},
                token=None,
            )
            result = http(
                "POST",
                f"{core_url}/auth/login_flow/{flow['flow_id']}",
                {"client_id": client_id, "username": username, "password": password},
                token=None,
            )
            if result.get("type") != "create_entry":
                raise ApplyError(f"login of {name}: {result.get('type')} {result.get('errors')}")
            grant = http(
                "POST",
                core_url + "/auth/token",
                {"grant_type": "authorization_code", "code": result["result"], "client_id": client_id},
                token=None,
                form=True,
            )
            ws_url = core_url.replace("http", "ws", 1) + "/api/websocket"
            ws = WebSocket(ws_url).auth(grant["access_token"])
            try:
                for t in ws.call("auth/refresh_tokens"):
                    if t["type"] == "long_lived_access_token" and t["client_name"] == token_spec["clientName"]:
                        ws.call("auth/delete_refresh_token", refresh_token_id=t["id"])
                return ws.call(
                    "auth/long_lived_access_token",
                    client_name=token_spec["clientName"],
                    lifespan=token_spec["lifespanDays"],
                )
            finally:
                ws.close()
        finally:
            self.admin_ws.call("config/auth_provider/homeassistant/delete", username=username)

    # Core: config entries --------------------------------------------------

    def config_entries(self):
        for domain, want in self.state["configEntries"].items():
            entries = core("GET", f"/config/config_entries/entry?domain={domain}")
            if len(entries) > 1:
                raise ApplyError(f"{domain}: {len(entries)} config entries")
            if not entries:
                if not self.core_change(f"add integration {domain}"):
                    self.change(f"set {domain} options {want['options']}")
                    continue
                flow = core("POST", "/config/config_entries/flow", {"handler": domain})
                if flow["type"] == "form":
                    flow = core("POST", f"/config/config_entries/flow/{flow['flow_id']}", {})
                if flow["type"] != "create_entry":
                    raise ApplyError(f"{domain} config flow: {flow}")
                entry = flow["result"]
            else:
                entry = entries[0]
            if entry.get("disabled_by") and self.core_change(f"enable integration {domain}"):
                self.admin_ws.call("config_entries/disable", entry_id=entry["entry_id"], disabled_by=None)
            self.options(domain, entry["entry_id"], want["options"])

    def options(self, domain, entry_id, want):
        flow = core("POST", "/config/config_entries/options/flow", {"handler": entry_id})
        if flow["type"] != "form":
            raise ApplyError(f"{domain} options flow: {flow}")
        current = {}
        for field in flow["data_schema"]:
            suggested = (field.get("description") or {}).get("suggested_value")
            current[field["name"]] = suggested if suggested is not None else field.get("default")
        diff = sorted(k for k in want if current.get(k) != want[k])
        if not diff:
            core("DELETE", f"/config/config_entries/options/flow/{flow['flow_id']}")
            return
        if not self.core_change(f"set {domain} options {', '.join(diff)}"):
            core("DELETE", f"/config/config_entries/options/flow/{flow['flow_id']}")
            return
        done = core("POST", f"/config/config_entries/options/flow/{flow['flow_id']}", want)
        if done["type"] != "create_entry":
            raise ApplyError(f"{domain} options: {done.get('errors') or done}")


def main():
    request = json.load(sys.stdin)
    state = request["state"]
    run = Run(state, request["dryRun"])
    tokens = {}
    try:
        deferred = run.addons()
        user_ids = run.users()
        run.config_entries()
        for name in request["mint"]:
            token = run.mint(name, user_ids[name])
            if token is not None:
                tokens[name] = token
        if deferred:
            run.self_addon(*deferred)
    finally:
        if run._admin_ws is not None:
            run._admin_ws.close()
    json.dump({"changes": run.changes, "tokens": tokens}, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except (ApplyError, OSError, http.client.HTTPException) as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
