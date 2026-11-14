"""Merge the Nix-managed dashboards into Hermes One's connection registry.

The Hermes One launcher (./hermes-one-app.nix) runs this before it execs
the app, with HERMES_HOME set to the app's own data directory (never
~/.hermes). Hermes One keeps its connections in $HERMES_HOME/desktop.json,
key `connectionRegistry` (version 1: activeConnectionId + records of
{connectionId, name, config}; src/main/config.ts upstream).

Managed records have a fixed connectionId derived from the account
(`connection-` + 24 hex of sha256("nix-<account>")), so their chats and
sign-ins stay attached across launches. Each is a `remote` connection to
the agent's dashboard with remoteAuthMode oauth and the dashboard
transport; it snaps back to the spec on every launch, and one the spec no
longer names is dropped (the sidecar nix-managed-connections.json lists
the ids this script wrote; the app keeps no marker of its own). Records the user added survive, as does the
user's active pick while it still names a record; otherwise the spec's
primary becomes active. Other keys of desktop.json are left alone.

No credential is written: sign-ins live in the app's cookie partition
(its Electron userData), not here. An unreadable desktop.json, or a
registry of another version, is left untouched (the app itself refuses to
rewrite those too); the app then starts without the managed records.

Writes are a regular 0600 file, tmp + rename in the same directory.
"""

import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

REGISTRY_VERSION = 1


def connection_id(account: str) -> str:
    return "connection-" + hashlib.sha256(f"nix-{account}".encode()).hexdigest()[:24]


def remote_config(url: str) -> dict:
    return {
        "mode": "remote",
        "remoteUrl": url,
        "apiKey": "",
        "remoteAuthMode": "oauth",
        "remoteChatTransport": "dashboard",
        "sshChatTransport": "auto",
        "ssh": {
            "host": "",
            "port": 22,
            "username": "",
            "keyPath": "",
            "remotePort": 8642,
            "localPort": 18642,
        },
    }


def write_private(path: Path, data: bytes) -> None:
    if path.is_file() and not path.is_symlink() and path.read_bytes() == data:
        return
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def merge(doc: dict, spec: dict, previous: set) -> dict:
    managed = [
        {"connectionId": connection_id(account), "name": r["label"], "config": remote_config(r["url"])}
        for account, r in sorted(spec["remotes"].items())
    ]
    managed_ids = {r["connectionId"] for r in managed}

    registry = doc.get("connectionRegistry")
    own: list = []
    active = None
    if isinstance(registry, dict):
        active = registry.get("activeConnectionId")
        for record in registry.get("connections") or []:
            if not isinstance(record, dict):
                continue
            cid = record.get("connectionId")
            if cid in managed_ids or cid in previous:
                continue
            own.append(record)

    # A fresh install migrates an empty document into one "Local" record;
    # drop that one (it would point at a local install this build refuses).
    own = [
        r
        for r in own
        if not (r.get("name") == "Local" and (r.get("config") or {}).get("mode", "local") == "local")
    ]

    connections = managed + own
    ids = {r.get("connectionId") for r in connections}
    if active not in ids:
        active = connection_id(spec["primary"])
    out = dict(doc)
    out["connectionRegistry"] = {
        "version": REGISTRY_VERSION,
        "activeConnectionId": active,
        "connections": connections,
    }
    for legacy in (
        "connectionMode",
        "remoteUrl",
        "remoteApiKey",
        "remoteAuthMode",
        "remoteChatTransport",
        "sshChatTransport",
        "sshConfig",
    ):
        out.pop(legacy, None)
    return out


def main() -> int:
    spec = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    home = os.environ.get("HERMES_HOME")
    if not home:
        print("hermes-one-connections: HERMES_HOME is not set", file=sys.stderr)
        return 1
    path = Path(home) / "desktop.json"
    sidecar = Path(home) / "nix-managed-connections.json"
    try:
        previous = set(json.loads(sidecar.read_text(encoding="utf-8")))
    except (OSError, ValueError, TypeError):
        previous = set()
    doc: dict = {}
    if path.exists():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            print(f"hermes-one-connections: {path} is unreadable; left unchanged", file=sys.stderr)
            return 0
        if not isinstance(loaded, dict):
            print(f"hermes-one-connections: {path} is not an object; left unchanged", file=sys.stderr)
            return 0
        registry = loaded.get("connectionRegistry")
        if registry is not None and (not isinstance(registry, dict) or registry.get("version") != REGISTRY_VERSION):
            print(f"hermes-one-connections: {path} has an unknown registry; left unchanged", file=sys.stderr)
            return 0
        doc = loaded
    merged = merge(doc, spec, previous)
    write_private(path, (json.dumps(merged, indent=2) + "\n").encode("utf-8"))
    ids = sorted(connection_id(a) for a in spec["remotes"])
    write_private(sidecar, (json.dumps(ids) + "\n").encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
