"""Declare Home Assistant config entries before HA starts (ExecStartPre).

Usage: seed.py <config dir> <entries.json>

entries.json: a list of {"entry_id", "domain", "title", "data"} where a
data value {"file": "<path>"} is replaced by that file's content (stripped)
and {"json_file": "<path>"} by its parsed JSON: clan vars' runtime paths, so
no secret enters the nix store. Each entry is created in <config dir>/.storage/core.config_entries
when missing and its title/data updated when they differ; nothing else in
the file changes. HA is not running yet (this is its ExecStartPre), so the
offline edit cannot race HA's own writes.

Never fails HA's start: any problem (unknown storage version, unreadable
secret) is printed and the file is left as it is.
"""

import datetime
import json
import os
import sys
import tempfile

KNOWN_VERSION = 1
KNOWN_MINOR_MAX = 5


def resolve(value):
    if isinstance(value, dict) and set(value) == {"file"}:
        with open(value["file"]) as f:
            return f.read().strip()
    if isinstance(value, dict) and set(value) == {"json_file"}:
        with open(value["json_file"]) as f:
            return json.load(f)
    return value


def new_entry(spec, now):
    return {
        "created_at": now,
        "data": {},
        "disabled_by": None,
        "discovery_keys": {},
        "domain": spec["domain"],
        "entry_id": spec["entry_id"],
        "minor_version": 1,
        "modified_at": now,
        "options": {},
        "pref_disable_new_entities": False,
        "pref_disable_polling": False,
        "source": "user",
        "subentries": [],
        "title": spec["title"],
        "unique_id": None,
        "version": 1,
    }


def main(config_dir, specs_path):
    path = os.path.join(config_dir, ".storage", "core.config_entries")
    with open(specs_path) as f:
        specs = json.load(f)
    try:
        wanted = [
            dict(spec, data={k: resolve(v) for k, v in spec["data"].items()})
            for spec in specs
        ]
    except (OSError, ValueError) as e:
        print(f"config-entry seed: secret unreadable ({e}); entries unchanged")
        return

    if os.path.exists(path):
        with open(path) as f:
            store = json.load(f)
        if store.get("version") != KNOWN_VERSION or store.get("minor_version", 0) > KNOWN_MINOR_MAX:
            print(
                "config-entry seed: core.config_entries is version "
                f"{store.get('version')}.{store.get('minor_version')}, known up to "
                f"{KNOWN_VERSION}.{KNOWN_MINOR_MAX}; entries unchanged"
            )
            return
    else:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        store = {
            "version": KNOWN_VERSION,
            "minor_version": KNOWN_MINOR_MAX,
            "key": "core.config_entries",
            "data": {"entries": []},
        }

    entries = store["data"]["entries"]
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    changed = []
    for spec in wanted:
        # One entry per domain (each seeded integration is single-instance):
        # a hand-made one is taken over rather than duplicated.
        entry = next((e for e in entries if e.get("entry_id") == spec["entry_id"]), None)
        if entry is None:
            entry = next((e for e in entries if e.get("domain") == spec["domain"]), None)
        if entry is None:
            entry = new_entry(spec, now)
            entry["data"] = spec["data"]
            entries.append(entry)
            changed.append(f"{spec['domain']} created")
        elif entry["data"] != spec["data"] or entry["title"] != spec["title"]:
            entry["data"] = spec["data"]
            entry["title"] = spec["title"]
            entry["modified_at"] = now
            changed.append(f"{spec['domain']} updated")
        if entry.get("disabled_by") is not None:
            entry["disabled_by"] = None
            changed.append(f"{spec['domain']} re-enabled")

    if not changed:
        return
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config_entries.")
    with os.fdopen(fd, "w") as f:
        json.dump(store, f, indent=4)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    print("config-entry seed: " + ", ".join(changed))


if __name__ == "__main__":
    try:
        main(sys.argv[1], sys.argv[2])
    except Exception as e:  # never block HA's start
        print(f"config-entry seed failed: {type(e).__name__}: {e}")
