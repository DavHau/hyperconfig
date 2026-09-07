#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# A key entry in a compiled keymap. Either a bare `[ a, A ]` level list or an
# explicit `symbols[1]= [ ... ]`. xkbcli emits both spellings.
KEY_RE = re.compile(r"key\s+<([A-Z0-9_+\-]+)>\s*\{(.*?)\};", re.DOTALL)
SYMS_RE = re.compile(
    r"symbols\[\s*(?:Group)?\d+\s*\]\s*=\s*\[([^\]]*)\]", re.IGNORECASE
)
BARE_SYMS_RE = re.compile(r"\[([^\]]*)\]")

# `    Mod+Shift+Slash repeat=false { show-hotkey-overlay; }`
BIND_RE = re.compile(r"^(\s*)(\S+)(\s.*)$")

# The US level-1 keysyms translated by physical position. A compiled keymap
# spells punctuation by keysym NAME (`minus`), and letters and digits as bare
# characters (`q`, `1`). Letters and digits are absent on purpose: they keep
# their legend, because following the physical key would swap Y and Z on
# QWERTZ and move every letter bind out from under the user.
US_PUNCTUATION = frozenset(
    {
        "minus",
        "equal",
        "bracketleft",
        "bracketright",
        "semicolon",
        "apostrophe",
        "backslash",
        "comma",
        "period",
        "slash",
        "grave",
    }
)


def die(msg: str) -> None:
    sys.exit(f"niri-render-binds: {msg}")


def compile_keymap(
    layout: str, model: str, variant: str, options: str
) -> dict[str, list[str]]:
    """Keycode name -> its level-1..N keysyms in the first group."""
    cmd = ["xkbcli", "compile-keymap", "--layout", layout]
    if model:
        cmd += ["--model", model]
    if variant:
        cmd += ["--variant", variant]
    if options:
        cmd += ["--options", options]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        die(f"{' '.join(cmd)} failed:\n{proc.stderr.strip()}")

    keys: dict[str, list[str]] = {}
    for match in KEY_RE.finditer(proc.stdout):
        name, body = match.group(1), match.group(2)
        syms = SYMS_RE.search(body) or BARE_SYMS_RE.search(body)
        if not syms:
            continue
        keys[name] = [s.strip() for s in syms.group(1).split(",")]
    if not keys:
        die(f"compiled an empty keymap for layout {layout!r}")
    return keys


def lowering_map(target: str, model: str, variant: str, options: str) -> dict[str, str]:
    """US level-1 keysym -> the keysym on the same physical key under `target`.

    niri matches a bind against the level-1 keysym of the ACTIVE layout. So a
    chord written for US is dead on another layout, not merely awkward. On
    `de`, `slash`, `equal`, `bracketleft` and `bracketright` have no level-1
    key, and `Mod+Minus` moves to a different physical key. Adding `us` as a
    second group does not help. niri resolves a press through smithay's
    `raw_latin_sym_or_raw_current_sym`, which searches the other groups only
    when the sym is non-ASCII, and `minus` and `plus` are ASCII. See niri
    `src/input/mod.rs`.

    Only punctuation is translated. A letter or digit keeps its legend, and
    anything named (Escape, Print, Page_Down, XF86*) is already layout-neutral.
    """
    if target == "us":
        return {}

    # Both keymaps use the same model, variant and options, so only the layout
    # differs. Option-induced remaps then cancel out. Under `caps:swapescape`
    # both sides put Escape on <CAPS>, so `Mod+Escape` stays unchanged and
    # still fires on the physical CapsLock key.
    us = compile_keymap("us", model, variant, options)
    them = compile_keymap(target, model, variant, options)

    mapping: dict[str, str] = {}
    for keycode, us_syms in us.items():
        their_syms = them.get(keycode)
        if not us_syms or not their_syms:
            continue
        src, dst = us_syms[0], their_syms[0]
        if src == dst:
            continue
        if src not in US_PUNCTUATION:
            continue
        mapping[src] = dst

    # A non-injective map would silently drop binds: two chords would collapse
    # onto one trigger and niri's find_configured_bind returns the first match.
    seen: dict[str, str] = {}
    for src, dst in sorted(mapping.items()):
        if dst in seen:
            die(
                f"layout {target!r} puts {seen[dst]!r} and {src!r} on the same "
                f"keysym {dst!r}; two binds would collapse onto one key"
            )
        seen[dst] = src
    return mapping


def lower_chord(chord: str, by_name: dict[str, str]) -> str:
    """Translate a chord's KEY token, leaving its modifiers untouched."""
    parts = chord.split("+")
    key = parts[-1]
    replacement = by_name.get(key.lower())
    if replacement:
        parts[-1] = replacement
    return "+".join(parts)


def render_bind(chord: str, spec: dict) -> str:
    title = spec.get("title")
    props = f' hotkey-overlay-title="{title}"' if title else ""
    spawn, action = spec.get("spawn"), spec.get("action")
    if (spawn is None) == (action is None):
        die(f"bind {chord!r} must set exactly one of spawn/action")
    if spawn is not None:
        args = " ".join(f'"{a}"' for a in spawn)
        body = f"spawn {args};"
    else:
        body = f"{action};"
    return f"    {chord}{props} {{ {body} }}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kdl", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument(
        "--binds", required=True, help="JSON: chord -> spec, or null to delete"
    )
    ap.add_argument("--layout", default="us")
    ap.add_argument("--model", default="")
    ap.add_argument("--variant", default="")
    ap.add_argument("--options", default="")
    args = ap.parse_args()

    # A comma-separated layout list means niri starts on the FIRST group, and
    # that group is what binds resolve against.
    target = args.layout.split(",")[0].strip() or "us"
    by_name = lowering_map(target, args.model, args.variant, args.options)

    # `--binds` carries an ordered [chord, spec] pair list. A Nix attrset sorts
    # its keys, so the list is what brings the model's order across. dict()
    # keeps the first position for a repeated chord and the last spec, so a
    # user bind that overrides a model chord keeps the model's position.
    pending: dict[str, dict | None] = dict(json.loads(args.binds))

    lines = Path(args.kdl).read_text().split("\n")
    try:
        start = lines.index("binds {")
        end = start + lines[start:].index("}")
    except ValueError:
        die("could not locate the `binds {` block; upstream's kdl changed shape")

    out: list[str] = []
    for line in lines[start + 1 : end]:
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            out.append(line)
            continue
        match = BIND_RE.match(line)
        if not match:
            die(f"unparseable bind line: {line!r}")
        indent, chord, rest = match.groups()
        if "{" in stripped and not stripped.endswith("}"):
            die(
                f"bind {chord!r} spans multiple lines; the renderer assumes one line per bind"
            )

        if chord in pending:
            spec = pending.pop(chord)
            if spec is None:
                continue  # removed
            out.append(render_bind(lower_chord(chord, by_name), spec))
            continue
        out.append(f"{indent}{lower_chord(chord, by_name)}{rest}")

    # Anything left did not exist upstream: append it. Deleting an absent chord
    # is a config error, not a no-op -- it means the chord was misspelled.
    for chord, spec in pending.items():
        if spec is None:
            die(f"bind {chord!r} is set to null but no such bind exists to remove")
        out.append(render_bind(lower_chord(chord, by_name), spec))

    result = lines[: start + 1] + out + lines[end:]
    Path(args.out).write_text("\n".join(result))


if __name__ == "__main__":
    main()
