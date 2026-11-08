"""Converge one Home Assistant OS instance to its declared state.

Runs with python3 (stdlib only) inside the SSH add-on, which holds the
Supervisor token. Reads one JSON object on stdin:

    {"state": <one host of hosts.nix>, "dryRun": bool, "mint": [user names],
     "integrations": {domain: <built by apply.py>}}

Reports each change on stderr ("would" in a dry run) and prints one JSON
object on stdout for apply.py: {"changes": [...], "tokens": {user: token},
"rerunSshPort": port or null}. Tokens are never written anywhere else.

{"probe": [domains]} instead only prints {"haVersion": running Core
version, "configured": {domain: has a config entry}}, which apply.py needs
to build the patched integrations: each is either {"haVersion", "patch",
"files": {path: base64}}, installed as Core's custom_components/<domain>
(overriding the built-in) with a MARKER naming the HA version and patch it
was built for, or {"haVersion", "remove": why}, which removes it. Core is
restarted once after any of that changed. A directory without the MARKER is
someone else's custom component and is never touched.

Official APIs only: Supervisor REST (add-ons, backups, Core info and
restart), Core REST via the Supervisor proxy (config entries), Core
websocket via the Supervisor proxy (users, credentials), and Core's own
login flow plus the user's websocket to mint the long-lived token. The one
file system write is the patched integrations' custom_components in /config,
the documented place for custom integrations.

Moving off a declared-absent SSH add-on that holds the session (the
official core_ssh, as on casa) takes two runs, since that add-on cannot be
uninstalled from its own session and holds the port its replacement wants:
its `replacedBy` (hosts.nix) names the replacement and a temporary network.
Run 1 (session in core_ssh) only installs, configures and starts the
replacement on the temporary port, then stops and asks for a rerun through
that port. Run 2 (session in the replacement, /addons/self/info) is an
ordinary run: it uninstalls core_ssh and, last, moves its own add-on to the
declared port with the detached restart.
"""

import base64
import http.client
import json
import os
import secrets
import shutil
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

# Core's /config, as the add-on mounts it.
CORE_CONFIG = "/homeassistant"
CUSTOM_COMPONENTS = CORE_CONFIG + "/custom_components"
MARKER = ".hyperconfig.json"

# Detached restart of the session's own add-on (Run.self_addon): argv is the
# URL and the log file; the token comes from the inherited environment.
RESTART_LOG = "/data/hyperconfig-apply-restart.log"
RESTART = """
import json, os, sys, time, urllib.request
url, log = sys.argv[1:3]
time.sleep(2)
req = urllib.request.Request(
    url, method="POST", headers={"Authorization": "Bearer " + os.environ["SUPERVISOR_TOKEN"]}
)
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        reply = json.loads(resp.read() or b"{}")
    error = None if reply.get("result") == "ok" else repr(reply)[:500]
except Exception as e:
    error = repr(e)[:500]
if error:
    with open(log, "w") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + "POST " + url + ": " + error + "\\n")
"""


class ApplyError(Exception):
    pass


def fetch(method, url, body=None, token=TOKEN, form=False, timeout=600):
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
    reply = fetch(method, SUPERVISOR + path, body)
    if reply.get("result") != "ok":
        raise ApplyError(f"{method} {path}: {reply}")
    return reply.get("data")


def core(method, path, body=None):
    return fetch(method, f"{SUPERVISOR}/core/api{path}", body)


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
        """Converge add-ons; return the session's own pending change.

        Returns ("migrate", port) when the session runs in a declared-absent
        add-on with a replacement (run 1 of the move, see the module doc),
        else ("self", (slug, body)) or None.
        """
        self_slug = supervisor("GET", "/addons/self/info")["slug"]
        installed = {a["slug"] for a in supervisor("GET", "/addons")["addons"]}
        wants = self.state["addons"]
        self_want = wants.get(self_slug, {"present": True})
        if not self_want["present"]:
            move = self_want.get("replacedBy")
            if move is None:
                raise ApplyError(f"{self_slug}: refusing to uninstall the add-on of this session")
            new = move["slug"]
            print(
                f"{self_slug}: this session runs in it; moving to {new} on {move['network']} first",
                file=sys.stderr,
            )
            self.addon(new, dict(wants[new], network=move["network"]), installed)
            return ("migrate", next(iter(move["network"].values())))
        deferred = None
        for slug, want in wants.items():
            if not want["present"]:
                if slug in installed and self.change(f"uninstall add-on {slug}"):
                    supervisor("POST", f"/addons/{slug}/uninstall")
                continue
            pending = self.addon(slug, want, installed, own=slug == self_slug)
            if pending:
                deferred = ("self", pending)
        return deferred

    def addon(self, slug, want, installed, own=False):
        """Converge one present add-on; for the session's own, return its pending (slug, body)."""
        if slug not in installed:
            repos = {r["source"] for r in supervisor("GET", "/store/repositories")}
            if want["repository"] not in repos and self.change(
                f"add add-on repository {want['repository']}"
            ):
                supervisor("POST", "/store/repositories", {"repository": want["repository"]})
            if not self.change(f"install add-on {slug}"):
                self.change(f"configure and start add-on {slug}")
                return None
            supervisor("POST", f"/store/addons/{slug}/install")
        info = supervisor("GET", f"/addons/{slug}/info")
        body = {}
        for key in ("boot", "network", "options"):
            if info.get(key) != want[key]:
                body[key] = want[key]
        if own:
            return (slug, body) if body else None
        if body and self.change(f"set add-on {slug} {', '.join(sorted(body))}"):
            supervisor("POST", f"/addons/{slug}/options", body)
            if info["state"] == "started" and self.change(f"restart add-on {slug}"):
                supervisor("POST", f"/addons/{slug}/restart")
        if want["started"] and info["state"] != "started" and self.change(f"start add-on {slug}"):
            supervisor("POST", f"/addons/{slug}/start")
        return None

    def self_addon(self, slug, body):
        """Change the session's own add-on, then restart it detached."""
        if not self.change(f"set add-on {slug} {', '.join(sorted(body))} and restart it (drops this session)"):
            return
        supervisor("POST", f"/addons/{slug}/options", body)
        # The restart kills this container, this script and its ssh session:
        # leave it to a detached process, after the result has been printed.
        # The token stays in its environment, out of argv; a failed request
        # lands in RESTART_LOG (the add-on's persistent /data), which the next
        # run reports, since the saved options would otherwise look converged.
        subprocess.Popen(
            [sys.executable, "-c", RESTART, f"{SUPERVISOR}/addons/{slug}/restart", RESTART_LOG],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def report_failed_restart(self):
        try:
            with open(RESTART_LOG) as f:
                log = f.read().strip()
        except FileNotFoundError:
            return
        print(
            f"warning: the previous run's detached add-on restart failed ({log}); its saved options"
            " may not be active: restart that add-on by hand",
            file=sys.stderr,
        )
        if not self.dry_run:
            os.remove(RESTART_LOG)

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
            flow = fetch(
                "POST",
                core_url + "/auth/login_flow",
                {"client_id": client_id, "handler": ["homeassistant", None], "redirect_uri": client_id},
                token=None,
            )
            result = fetch(
                "POST",
                f"{core_url}/auth/login_flow/{flow['flow_id']}",
                {"client_id": client_id, "username": username, "password": password},
                token=None,
            )
            if result.get("type") != "create_entry":
                raise ApplyError(f"login of {name}: {result.get('type')} {result.get('errors')}")
            grant = fetch(
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

    # Core: patched integrations --------------------------------------------

    def patched_integrations(self, integrations):
        """Converge the overrides apply.py built; return whether Core needs a restart.

        It does after a change and also while Core still runs other code than
        the files hold (a previous run's restart failed): per its manifest,
        the built-in where none is wanted, else our override's version.
        """
        if not integrations:
            return False
        version = supervisor("GET", "/core/info")["version"]
        restart = False
        for domain, want in integrations.items():
            if want["haVersion"] != version:
                raise ApplyError(f"patched {domain}: built for HA {want['haVersion']}, but {version} runs; rerun")
            path = os.path.join(CUSTOM_COMPONENTS, domain)
            current = read_tree(path)
            if current is not None and MARKER not in current:
                raise ApplyError(f"{path} is not this tool's (no {MARKER}); refusing to touch it")
            loaded = self.admin_ws.call("manifest/get", integration=domain)
            if "files" not in want:
                if not loaded["is_built_in"]:
                    restart = True
                if current is not None:
                    restart = True
                    if self.core_change(f"remove patched {domain} ({path}): {want['remove']}"):
                        shutil.rmtree(path)
                continue
            if loaded["is_built_in"] or loaded.get("version") != version:
                restart = True
            desired = {p: base64.b64decode(data) for p, data in want["files"].items()}
            marker = {"haVersion": version, "patch": want["patch"]}
            desired[MARKER] = (json.dumps(marker, indent=2) + "\n").encode()
            if current == desired:
                continue
            restart = True
            if self.core_change(f"install patched {domain} ({path}) built for HA {version}: {want['patch']}"):
                write_tree(path, desired)
        return restart

    def restart_core(self):
        if not self.change("restart Home Assistant Core"):
            return
        if self._admin_ws is not None:
            self._admin_ws.close()
            self._admin_ws = None
        supervisor("POST", "/core/restart")


def read_tree(path):
    """{relative path: bytes} of the files under path (bytecode caches aside), None if absent."""
    if not os.path.isdir(path):
        return None
    files = {}
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            with open(full, "rb") as f:
                files[os.path.relpath(full, path)] = f.read()
    return files


def write_tree(path, files):
    """Replace the directory path with files, staged next to Core's config."""
    stage = os.path.join(CORE_CONFIG, f".hyperconfig-{os.path.basename(path)}-new")
    shutil.rmtree(stage, ignore_errors=True)
    for rel, data in files.items():
        full = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.isdir(path):
        shutil.rmtree(path)
    os.rename(stage, path)


def main():
    request = json.load(sys.stdin)
    if "probe" in request:
        json.dump(
            {
                "haVersion": supervisor("GET", "/core/info")["version"],
                "configured": {
                    domain: bool(core("GET", f"/config/config_entries/entry?domain={domain}"))
                    for domain in request["probe"]
                },
            },
            sys.stdout,
        )
        return
    state = request["state"]
    run = Run(state, request["dryRun"])
    tokens = {}
    rerun_port = None
    run.report_failed_restart()
    try:
        pending = run.addons()
        if pending and pending[0] == "migrate":
            # Run 1 of moving off the session's add-on: nothing else until
            # the session runs in the replacement.
            rerun_port = pending[1]
        else:
            user_ids = run.users()
            run.config_entries()
            restart = run.patched_integrations(request.get("integrations"))
            for name in request["mint"]:
                token = run.mint(name, user_ids[name])
                if token is not None:
                    tokens[name] = token
            if restart:
                run.restart_core()
            if pending:
                run.self_addon(*pending[1])
    finally:
        if run._admin_ws is not None:
            run._admin_ws.close()
    json.dump({"changes": run.changes, "tokens": tokens, "rerunSshPort": rerun_port}, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except (ApplyError, OSError, ValueError, http.client.HTTPException) as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
