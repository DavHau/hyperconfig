"""Remove keys from an agent's .env before its dashboard starts (./agents.nix).

usage: drop-env-keys.py ENV_FILE KEY_REGEX

Hermes reads the file with python-dotenv after its own clean-up
(hermes_cli/env_loader.py): a UTF-32/UTF-16 or UTF-8 byte order mark is
honoured, NULs are removed, lines end at CR as well as LF, and a file that is
not UTF-8 is read as latin-1. This script decodes the same way and finds the
keys with python-dotenv's own parser, so no spelling (export, quotes, spaces,
a lone CR, a BOM, NUL padding) keeps a key from it that hermes would load.
Bindings whose key fully matches KEY_REGEX are dropped; every other binding
is written back verbatim. The file is only rewritten when something goes,
then as UTF-8 through a 0600 temporary file in the same directory.
"""

import codecs
import io
import os
import re
import sys
import tempfile

from dotenv.parser import parse_stream


def decode(raw):
    for bom, codec in (
        (codecs.BOM_UTF32_LE, "utf-32"),
        (codecs.BOM_UTF32_BE, "utf-32"),
        (codecs.BOM_UTF16_LE, "utf-16"),
        (codecs.BOM_UTF16_BE, "utf-16"),
    ):
        if raw.startswith(bom):
            return raw.decode(codec, errors="replace")
    raw = raw.removeprefix(codecs.BOM_UTF8)
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def main():
    path, pattern = sys.argv[1], re.compile(sys.argv[2])
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return
    text = decode(raw).replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n")
    kept, dropped = [], []
    for binding in parse_stream(io.StringIO(text)):
        if binding.key is not None and pattern.fullmatch(binding.key):
            dropped.append(binding.key)
        else:
            kept.append(binding.original.string)
    if not dropped:
        return
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".env_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("".join(kept))
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    print(f"dropped from {path}: {', '.join(sorted(set(dropped)))}")


if __name__ == "__main__":
    main()
