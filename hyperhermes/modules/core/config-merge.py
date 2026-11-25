"""Merge an agent's Nix settings into its config.yaml and its named profiles' ones, in one process.

usage: config-merge.py SETTINGS.json HOME_CONFIG [PROFILE_CONFIG...]

Run as the agent before every gateway start (./agents.nix, preStart). The
merge is upstream's (hermes-agent nix/configMergeScript.nix, same YAML
settings): a deep merge where the Nix keys win and every key the owner or
the dashboard added stays. HOME_CONFIG is created when missing; a
PROFILE_CONFIG that is no file (a profile hermes has not written a
config.yaml for yet, or the unmatched glob) is left alone.

One interpreter for all of them, not one per file: an agent with several
profiles paid a Python + ruamel startup for each, which under a fleet-wide
restart was what pushed its preStart past the unit's start timeout.

Stale MCP servers: an mcp_servers entry the Nix settings no longer set
stays in the file (the merge only adds and overrides), so a server a
module once installed and later dropped keeps being started from a store
path the garbage collector has since removed ("failed initial connection
... parking" on every start). An entry the settings don't set whose
command is a /nix/store path that no longer exists is dropped: it can't
run anyway. Every other entry (the owner's own servers, url ones, a store
command that still exists) is never touched.

A file is only rewritten when its content changes, through a temporary
file beside it and a rename, so a start killed mid-write never leaves a
truncated config.yaml. Exit 1 when any file failed (the others are still
merged).
"""

import io
import json
import os
import re
import sys
import tempfile

from ruamel.yaml import YAML

yaml = YAML(typ="safe", pure=True)
# Existing configs use YAML 1.1 booleans such as yes and off.
yaml.version = (1, 1)
yaml.default_flow_style = False
yaml.sort_base_mapping_type_on_output = False

STORE_PATH = re.compile(r"^/nix/store/[^/\s]+")


def deep_merge(base, override):
    result = dict(base)
    for k, v in override.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = v
    return result


def dead_store_path(entry):
    """The entry's command's /nix/store path when that no longer exists, else None."""
    command = entry.get("command") if isinstance(entry, dict) else None
    m = STORE_PATH.match(command) if isinstance(command, str) else None
    if m and not os.path.lexists(m.group(0)):
        return m.group(0)
    return None


def drop_stale_mcp(merged, nix, label):
    servers = merged.get("mcp_servers")
    if not isinstance(servers, dict):
        return merged
    managed = nix.get("mcp_servers") if isinstance(nix.get("mcp_servers"), dict) else {}
    keep = {}
    for name, entry in servers.items():
        gone = None if name in managed else dead_store_path(entry)
        if gone is None:
            keep[name] = entry
        else:
            print(f"hermes: {label}: dropped MCP server {name!r} ({gone} no longer exists)", file=sys.stderr)
    if len(keep) != len(servers):
        merged = dict(merged)
        merged["mcp_servers"] = keep
    return merged


def dump(data):
    buf = io.StringIO()
    yaml.dump(data, buf)
    return buf.getvalue()


def merge_one(nix, path, create):
    real = os.path.realpath(path)
    if not os.path.isfile(real):
        if not create:
            return
        old_text, existing, mode = None, {}, 0o600
    else:
        with open(real) as f:
            old_text = f.read()
        existing = yaml.load(old_text) or {}
        mode = os.stat(real).st_mode & 0o7777
    merged = drop_stale_mcp(deep_merge(existing, nix), nix, path)
    text = dump(merged)
    if text == old_text:
        return
    fd, tmp = tempfile.mkstemp(prefix=".config.yaml.", dir=os.path.dirname(real))
    try:
        with os.fdopen(fd, "w") as f:
            os.fchmod(f.fileno(), mode)
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main():
    with open(sys.argv[1]) as f:
        nix = json.load(f)
    failed = False
    for i, path in enumerate(sys.argv[2:]):
        try:
            merge_one(nix, path, create=(i == 0))
        except Exception as e:
            print(f"hermes: could not merge the Nix settings into {path}: {e}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
