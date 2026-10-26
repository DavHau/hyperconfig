"""Merge the Nix-managed ssh agents into the hermes desktop connection files.

The hermes-desktop launcher (./default.nix) runs this before it execs the
app. Two files under $XDG_CONFIG_HOME/Hermes decide what the app connects
to:

- connections.json (v2), the Connections registry the user edits in
  Settings. Entries with a `nix-` id are managed: they snap back to the
  spec on every launch, and one the spec no longer names is dropped.
  Every other entry survives, as does the user's primary while it still
  names an entry; otherwise the spec's primary becomes it.
- connection.json (v1), the window backend. Written when absent, when it
  still carries the bytes this script last wrote (the sidecar records the
  sha256), or on first adoption (no sidecar of this version: the file then
  pointed at the retired local microVM). A gateway the user saved in
  Settings stays.

Every write is a regular 0600 file, tmp + rename in the same directory.
"""

import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

LOCAL_ENTRY = {"id": "local", "kind": "local", "label": "This device"}
REGISTRY_VERSION = 2
SIDECAR_VERSION = 2


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def render(value: object) -> bytes:
    return (json.dumps(value, indent=2) + "\n").encode("utf-8")


def write_private(path: Path, data: bytes) -> None:
    if path.is_file() and not path.is_symlink() and path.read_bytes() == data:
        return
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        if path.is_symlink():
            path.unlink()
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def main() -> int:
    spec = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    hermes_dir = config_home / "Hermes"
    registry_path = hermes_dir / "connections.json"
    connection_path = hermes_dir / "connection.json"
    sidecar_path = hermes_dir / "nix-managed-connections.json"

    managed = [dict(LOCAL_ENTRY)] + [
        {"id": f"nix-{name}", "kind": "ssh", "label": r["label"], "host": r["host"], "user": r["user"]}
        for name, r in sorted(spec["remotes"].items())
    ]
    managed_ids = {e["id"] for e in managed}

    registry = load_json(registry_path)
    if not isinstance(registry, dict) or registry.get("version") != REGISTRY_VERSION:
        registry = {}
    old = registry.get("connections")
    survivors = [
        e
        for e in (old if isinstance(old, list) else [])
        if isinstance(e, dict) and e.get("kind") != "local" and not str(e.get("id", "")).startswith("nix-")
    ]
    valid = managed_ids | {e.get("id") for e in survivors}
    primary = registry.get("primary")
    if primary not in valid:
        primary = f"nix-{spec['primary']}"
    registry.update({"version": REGISTRY_VERSION, "primary": primary, "connections": managed + survivors})
    write_private(registry_path, render(registry))

    target = spec["remotes"][spec["primary"]]
    rendered = render(
        {
            "mode": "ssh",
            "remote": {"mode": "ssh", "host": target["host"], "user": target["user"]},
            "profiles": {},
        }
    )
    sidecar = load_json(sidecar_path)
    adopted = isinstance(sidecar, dict) and sidecar.get("version") == SIDECAR_VERSION
    connection_sha = sidecar.get("connectionSha256") if adopted else None
    try:
        existing = connection_path.read_bytes()
    except OSError:
        existing = None
    if existing is None or not adopted or hashlib.sha256(existing).hexdigest() == connection_sha:
        write_private(connection_path, rendered)
        connection_sha = hashlib.sha256(rendered).hexdigest()
    write_private(
        sidecar_path,
        render({"version": SIDECAR_VERSION, "connectionSha256": connection_sha}),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
