"""Consistent copies of one hermes agent's SQLite databases, for borg.

Usage: hermes-state-dump.py <HERMES_HOME> <dump dir>
Runs as the agent's own uid (the tree and the dump are the agent's), so
nothing here is trusted beyond that uid's rights. Every *.db, *.sqlite and
*.sqlite3 file under HERMES_HOME (one filesystem, no symlinks followed,
caches and the browser profile skipped) is copied with SQLite's online
backup API to <dump dir>/<relative path>; the new tree replaces the old
one only when complete. Exit 1 if any database failed (the rest is kept).
"""

import os
import shutil
import sqlite3
import sys

SKIP = {"cache", "browser-profile", "image_cache", "audio_cache", "sandboxes"}
SUFFIXES = (".db", ".sqlite", ".sqlite3")


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.isdir(src):
        return 0
    new = dst + ".new"
    shutil.rmtree(new, ignore_errors=True)
    os.makedirs(new, mode=0o700)
    dev = os.stat(src).st_dev
    rc = 0
    for root, dirs, files in os.walk(src):
        rel_root = os.path.relpath(root, src)
        keep = []
        for d in dirs:
            p = os.path.join(root, d)
            if rel_root == "." and d in SKIP:
                continue
            if os.path.islink(p) or os.lstat(p).st_dev != dev:
                continue
            keep.append(d)
        dirs[:] = keep
        for f in files:
            path = os.path.join(root, f)
            if not f.endswith(SUFFIXES) or os.path.islink(path):
                continue
            out = os.path.join(new, os.path.relpath(path, src))
            os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
            try:
                s = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
                d = sqlite3.connect(out)
                with d:
                    s.backup(d)
                d.close()
                s.close()
            except sqlite3.Error as e:
                print(f"dump failed: {path}: {e}", file=sys.stderr)
                rc = 1
    shutil.rmtree(dst, ignore_errors=True)
    os.rename(new, dst)
    return rc


if __name__ == "__main__":
    sys.exit(main())
