"""herdr-space-machines: declare the spaces as saved herdr SSH machines.

herdr keeps its saved machines in $XDG_STATE_HOME/herdr/client/endpoints.json
({"version": 1, "ssh": [{id, label, target, session, enabled}]}, unknown
fields rejected); open clients reread it every second. This upserts the
entries in SPACES_FILE (a JSON list of {id, label, target, session}),
each under a fixed id derived from its `id` name, and removes entries this
script added earlier that are no longer declared (their ids and declared
labels are kept in hyperconfig-spaces.json next to it). A declared label
that changed (a rename) replaces the entry's label in place, under the
same id: never a second entry. Everything else in the file is herdr's
and the user's and is left alone; a label the user set on a managed entry
(different from the one declared last time) and the enabled flag are kept.
A machine the user already saved by hand with the same target and session
is not added again. A removed entry that herdr had selected is unselected
(herdr refuses a catalog whose selected_profile is gone).

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
        managed_before = json.loads(managed_path.read_text())
    except (FileNotFoundError, ValueError):
        managed_before = {}
    # the old format: a list of ids, no labels (the label is then replaced)
    if isinstance(managed_before, list):
        managed_before = {i: None for i in managed_before}
    previously = set(managed_before)

    wanted = {space_id(s["id"]): s for s in declared}
    before = json.dumps(catalog, sort_keys=True)

    # retired spaces: only entries this script made
    retired = previously - set(wanted)
    entries[:] = [e for e in entries if e.get("id") not in retired]
    if catalog.get("selected_profile") in retired:
        del catalog["selected_profile"]

    by_id = {e.get("id"): e for e in entries}
    for pid, s in wanted.items():
        entry = by_id.get(pid)
        if entry is not None:
            if entry.get("label") == managed_before.get(pid) or managed_before.get(pid) is None:
                entry["label"] = s["label"]
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
    managed = {pid: s["label"] for pid, s in sorted(wanted.items())}
    if managed_before != managed:
        write_private(managed_path, managed)


if __name__ == "__main__":
    main()
