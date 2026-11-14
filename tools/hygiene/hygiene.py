#!/usr/bin/env python3
"""Repo hygiene lint for hyperconfig (text only, no Nix evaluation).

    hygiene.py [--root DIR] [--report] [--update-baseline]

Finds the drift CONVENTIONS.md describes:

  unimported   a modules/nixos .nix file no other file references in code
  dangling     a ./ ../ or repo-root path in a .nix file (code or comment)
               that does not exist
  generator    a clan vars generator name off the `<feature>-<what>`
               scheme, or one declared in machines/*/configuration.nix
  sshkey       an ssh public key literal outside modules/admin-ssh-keys.nix
               (always a violation when it repeats one of the admin keys)
  machine-loc  a machines/*/configuration.nix over the line budget

Default (the flake check `hygiene`): fail only on violations that are
neither in tools/hygiene/baseline.txt nor allowed by
tools/hygiene/allowlist.txt, so existing debt does not block anyone and
new debt does. It also fails on allowlist lines that match no current
violation, so the allowlist cannot rot. machine-loc fails only when a file grows past its baseline
size. --report prints every current violation (the weekly hygiene job).
--update-baseline rewrites baseline.txt from the current state (after a
cleanup, or with a reason in the commit body when accepting new debt).
"""

import argparse
import fnmatch
import hashlib
import os
import re
import sys
from collections import defaultdict

HERE = "tools/hygiene"
BASELINE = f"{HERE}/baseline.txt"
ALLOWLIST = f"{HERE}/allowlist.txt"
SKIP_DIRS = {".git", ".jj", ".sbox", "__pycache__", "node_modules", ".direnv", "result"}
# Not repo source: generated maps and public var values.
SKIP_PREFIXES = ("vars/", "skills/hyperconfig-map/references/")
LOC_BUDGET = 250

REL_RE = re.compile(r"(?<![\w/.$}-])(\.\.?/[A-Za-z0-9_.+/-]+)")
# Repo-root paths worth checking. tools/, pkgs/, scripts/ are left out:
# upstream sources (hermes' tools/*.py, nixpkgs' pkgs/) share those names.
ROOT_DIRS = "modules/(?:nixos|clan|flake-parts|home-manager)|machines|hyperhermes|docs|home-networks|guests|skills"
ROOT_RE = re.compile(rf"(?<![\w/.$}}@:-])((?:{ROOT_DIRS})/[A-Za-z0-9_.+/-]+)")
GEN_RE = re.compile(r"(?<![\w-])generators\.(\"[^\"]+\"|[A-Za-z0-9_-]+)\s*=")
GEN_OK = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)+$")
KEY_RE = re.compile(r"(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+|sk-ssh-ed25519@openssh\.com) (AAAA[0-9A-Za-z+/=]{20,})")


def walk(root):
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            p = os.path.join(d, f)
            r = os.path.relpath(p, root).replace(os.sep, "/")
            if not r.startswith(SKIP_PREFIXES):
                yield r


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def code_part(line):
    """The line without its comment (rough: `#` in strings cuts too)."""
    s = line.lstrip()
    if s.startswith("#") or s.startswith("*") or s.startswith("/*"):
        return ""
    return line.split(" #", 1)[0] if " #" in line else line


def clean(t):
    t = t.rstrip(".,;:)`'\"")
    return t.rstrip("/") or t


def keyid(blob):
    return hashlib.sha256(blob.encode()).hexdigest()[:12]


def collect(root):
    files = list(walk(root))
    nix = [r for r in files if r.endswith(".nix")]
    texts = {r: read(os.path.join(root, r)) for r in nix}
    exists = lambda r: os.path.exists(os.path.join(root, r))
    out = []  # (kind, path, detail, note)

    # --- importers (code only) and dangling refs (code + comments)
    importers = defaultdict(set)
    for r, t in texts.items():
        d = os.path.dirname(r)
        for line in t.splitlines():
            code = code_part(line)
            for m in REL_RE.finditer(line):
                raw = m.group(1)
                if "${" in line[m.start() : m.end() + 2] or "*" in raw or "<" in raw:
                    continue
                ref = clean(raw)
                tgt = os.path.normpath(os.path.join(d, ref)).replace(os.sep, "/")
                if tgt.startswith(".."):
                    continue  # outside the repo (../afk and friends)
                if m.group(1) in code and exists(tgt):
                    if os.path.isdir(os.path.join(root, tgt)):
                        tgt = tgt + "/default.nix"
                    if tgt != r:
                        importers[tgt].add(r)
                elif not exists(tgt):
                    out.append(("dangling", r, ref, ""))
            for m in ROOT_RE.finditer(line):
                ref = clean(m.group(1))
                if "*" in ref or "<" in ref or "$" in ref:
                    continue
                # hyperhermes is its own flake: its files name paths from
                # hyperhermes/ as the root.
                if not exists(ref) and not (r.startswith("hyperhermes/") and exists("hyperhermes/" + ref)):
                    out.append(("dangling", r, ref, ""))

    for r in nix:
        if not r.startswith("modules/nixos/"):
            continue
        if r in importers:
            continue
        # a dir without default.nix referenced as a whole
        out.append(("unimported", r, "-", ""))

    # --- generator names
    for r, t in texts.items():
        for m in GEN_RE.finditer(t):
            name = m.group(1).strip('"')
            probe = re.sub(r"\$\{[^}]*\}", "x", name)
            if re.match(r"machines/[^/]+/configuration\.nix$", r):
                out.append(("generator", r, name, "declared in a machine file"))
            elif not GEN_OK.match(probe):
                out.append(("generator", r, name, "not <feature>-<what>"))

    # --- ssh public keys
    admin = set(KEY_RE.findall(texts.get("modules/admin-ssh-keys.nix", "")))
    for r, t in texts.items():
        if r == "modules/admin-ssh-keys.nix":
            continue
        for i, line in enumerate(t.splitlines(), 1):
            for m in KEY_RE.finditer(line):
                blob = m.group(1)
                tail = line[m.end() :].strip().strip('";').strip()
                note = f"line {i} {tail[:30]}".strip()
                if blob in admin:
                    out.append(("sshkey-admin", r, keyid(blob), note + " (copy of an admin-ssh-keys.nix key)"))
                else:
                    out.append(("sshkey", r, keyid(blob), note))

    # --- machine file size
    for r, t in texts.items():
        if re.match(r"machines/[^/]+/configuration\.nix$", r):
            n = t.count("\n")
            if n > LOC_BUDGET:
                out.append(("machine-loc", r, str(n), f"budget {LOC_BUDGET}"))

    # dedupe, stable order
    seen, res = set(), []
    for v in out:
        k = v[:3]
        if k not in seen:
            seen.add(k)
            res.append(v)
    return sorted(res)


def load_lines(path):
    try:
        lines = read(path).splitlines()
    except FileNotFoundError:
        return []
    return [l.split("#", 1)[0].split() for l in lines if l.split("#", 1)[0].strip()]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".")
    ap.add_argument("--report", action="store_true", help="print every current violation, exit 0")
    ap.add_argument("--update-baseline", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root)

    allow = load_lines(os.path.join(root, ALLOWLIST))

    def matches(x, v):
        kind, path, detail = v[:3]
        return (
            len(x) >= 2
            # copies of admin keys are always violations
            and kind != "sshkey-admin"
            and fnmatch.fnmatch(kind, x[0])
            and fnmatch.fnmatch(path, x[1])
            and (len(x) < 3 or fnmatch.fnmatch(detail, x[2]))
        )

    every = collect(root)
    found = [v for v in every if not any(matches(x, v) for x in allow)]
    # allowlist lines matching nothing: rot (the thing is gone, or the glob
    # can never match what collect() reports)
    stale = [x for x in allow if not any(matches(x, v) for v in every)]

    if a.update_baseline:
        body = [
            "# Known hygiene debt (tools/hygiene/hygiene.py --update-baseline).",
            "# <kind> <path> <detail>; the check fails only on entries not listed here.",
            "# Shrink it by fixing things; grow it only with a reason in the commit body.",
        ]
        body += [f"{k} {p} {d}" for k, p, d, _ in found]
        with open(os.path.join(root, BASELINE), "w", encoding="utf-8") as f:
            f.write("\n".join(body) + "\n")
        print(f"hygiene: wrote {BASELINE} ({len(found)} entries)")
        return

    if a.report:
        for x in stale:
            print(f"hygiene: stale allowlist line (matches nothing): {' '.join(x)}")
        by = defaultdict(list)
        for v in found:
            by[v[0]].append(v)
        print(f"hygiene report: {len(found)} violations")
        for k in sorted(by):
            print(f"\n## {k} ({len(by[k])})")
            for _, p, d, n in by[k]:
                print(f"- {p} {d}" + (f"  ({n})" if n else ""))
        return

    base = {tuple(x[:3]) for x in load_lines(os.path.join(root, BASELINE)) if len(x) >= 3}
    base_loc = {x[1]: int(x[2]) for x in load_lines(os.path.join(root, BASELINE)) if len(x) >= 3 and x[0] == "machine-loc"}
    new = []
    for k, p, d, n in found:
        if k == "machine-loc":
            if p in base_loc and int(d) <= base_loc[p]:
                continue
            new.append((k, p, d, n + (f", baseline {base_loc[p]}" if p in base_loc else "")))
        elif (k, p, d) not in base:
            new.append((k, p, d, n))
    cur = {v[:3] for v in found}
    gone = [b for b in sorted(base) if b not in cur and b[0] != "machine-loc"]
    if gone:
        print(f"hygiene: {len(gone)} baseline entries are fixed; drop them with `python3 {HERE}/hygiene.py --update-baseline`")
    if stale:
        print(f"hygiene: {ALLOWLIST} lines that match nothing (drop them):", file=sys.stderr)
        for x in stale:
            print(f"  {' '.join(x)}", file=sys.stderr)
    if new:
        print("hygiene: new violations (see CONVENTIONS.md):", file=sys.stderr)
        for k, p, d, n in new:
            print(f"  {k} {p} {d}" + (f"  ({n})" if n else ""), file=sys.stderr)
        print(
            "\nFix them, or allow a deliberate case in tools/hygiene/allowlist.txt"
            " (with a reason), or accept the debt with --update-baseline and say why in the commit body.",
            file=sys.stderr,
        )
    if new or stale:
        sys.exit(1)
    print(f"hygiene: ok ({len(found)} known violations in the baseline)")


if __name__ == "__main__":
    main()
