"""herdr-pin-config: force [session] resume_agents_on_restore = false.

herdr's agent resume re-launches agent panes after a server restart as
`<agent> --resume=<session>` with the bare binary, bypassing wrappers
such as afk (its distro config, rules and sandbox). config.toml stays
user-owned, so only this one key is rewritten, comments and layout
preserved via tomlkit, and only when it differs.
"""
import os
import tempfile
from pathlib import Path

import tomlkit


def config_path():
    explicit = os.environ.get("HERDR_CONFIG_PATH")
    if explicit:
        return Path(explicit)
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return Path(base) / "herdr" / "config.toml"


def main():
    path = config_path()
    try:
        doc = tomlkit.parse(path.read_text())
    except FileNotFoundError:
        doc = tomlkit.document()
    session = doc.setdefault("session", tomlkit.table())
    if session.get("resume_agents_on_restore") is False:
        return
    session["resume_agents_on_restore"] = False
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".config.toml.")
    with os.fdopen(fd, "w") as f:
        f.write(tomlkit.dumps(doc))
    if path.exists():
        os.chmod(tmp, path.stat().st_mode & 0o7777)
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
