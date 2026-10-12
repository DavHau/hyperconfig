"""herdr-sound-toggle {status|toggle}

Flips [ui.sound] enabled in herdr's config.toml (comments and layout
preserved via tomlkit) and asks the running server to reload it.
Unset means enabled, matching herdr's default.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import tomlkit


def config_path():
    explicit = os.environ.get("HERDR_CONFIG_PATH")
    if explicit:
        return Path(explicit)
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return Path(base) / "herdr" / "config.toml"


def load(path):
    try:
        return tomlkit.parse(path.read_text())
    except FileNotFoundError:
        return tomlkit.document()


def enabled(doc):
    return bool(doc.get("ui", {}).get("sound", {}).get("enabled", True))


def status():
    if enabled(load(config_path())):
        print(json.dumps({
            "icon": "bell",
            "iconColor": "primary",
            "tooltip": "herdr sounds: ON — click to mute",
        }))
    else:
        print(json.dumps({
            "icon": "bell-off",
            "tooltip": "herdr sounds: OFF — click to unmute",
        }))


def toggle():
    path = config_path()
    doc = load(path)
    ui = doc.setdefault("ui", tomlkit.table())
    sound = ui.setdefault("sound", tomlkit.table())
    sound["enabled"] = not enabled(doc)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".config.toml.")
    with os.fdopen(fd, "w") as f:
        f.write(tomlkit.dumps(doc))
    if path.exists():
        os.chmod(tmp, path.stat().st_mode & 0o7777)
    os.replace(tmp, path)
    # No running server is fine: the next start reads the file.
    subprocess.run(
        ["@herdr@", "server", "reload-config"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "status":
        status()
    elif cmd == "toggle":
        toggle()
    else:
        print("usage: herdr-sound-toggle {status|toggle}", file=sys.stderr)
        sys.exit(2)
