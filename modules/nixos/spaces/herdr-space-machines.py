"""herdr-space-machines: declare the spaces as saved herdr SSH machines.

herdr keeps its saved machines in $XDG_STATE_HOME/herdr/client/endpoints.json
({"version": 1, "ssh": [{id, label, target, session, enabled}]}, unknown
fields rejected); open clients reread it every second. This upserts the
entries in SPACES_FILE (a JSON list of {name, label, target, session}),
each under a fixed id derived from its name, and removes entries this
script added earlier that are no longer declared (their ids are kept in
hyperconfig-spaces.json next to it). Everything else in the file is
herdr's and the user's and is left alone; a label or the enabled flag the
user changed on a managed entry is kept too. A machine the user already
saved by hand with the same target and session is not added again.

Never follows a symlink, writes atomically with mode 0600 (as herdr
does), and leaves a catalog of another version untouched.
"""
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return Path(base) / "herdr" / "client"


def space_id(name):
    return hashlib.sha256(f"hyperconfig-space:{name}".encode()).hexdigest()[:32]


def write_private(path, data):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        sys.exit(f"herdr-space-machines: refusing to replace {path}: not a regular file")
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def main():
    declared = json.loads(Path(os.environ["SPACES_FILE"]).read_text())
    directory = state_dir()
    catalog_path = directory / "endpoints.json"
    managed_path = directory / "hyperconfig-spaces.json"

    if catalog_path.is_symlink():
        sys.exit(f"herdr-space-machines: refusing to follow the symlink {catalog_path}")
    try:
        catalog = json.loads(catalog_path.read_text())
    except FileNotFoundError:
        catalog = {"version": 1, "ssh": []}
    if catalog.get("version") != 1:
        print(f"herdr-space-machines: {catalog_path} has version {catalog.get('version')}, not 1; left alone", file=sys.stderr)
        return
    entries = catalog.setdefault("ssh", [])

    try:
        previously = set(json.loads(managed_path.read_text()))
    except (FileNotFoundError, ValueError):
        previously = set()

    wanted = {space_id(s["name"]): s for s in declared}
    before = json.dumps(catalog, sort_keys=True)

    # retired spaces: only entries this script made
    entries[:] = [e for e in entries if e.get("id") not in previously - set(wanted)]

    by_id = {e.get("id"): e for e in entries}
    for pid, s in wanted.items():
        entry = by_id.get(pid)
        if entry is not None:
            entry["target"] = s["target"]
            entry["session"] = s["session"]
            continue
        if any(e.get("target") == s["target"] and e.get("session") == s["session"] for e in entries):
            continue
        entries.append({
            "id": pid,
            "label": s["label"],
            "target": s["target"],
            "session": s["session"],
            "enabled": True,
        })

    directory.mkdir(parents=True, exist_ok=True)
    if json.dumps(catalog, sort_keys=True) != before or not catalog_path.exists():
        write_private(catalog_path, catalog)
    managed = sorted(wanted)
    if previously != set(managed):
        write_private(managed_path, managed)


if __name__ == "__main__":
    main()
