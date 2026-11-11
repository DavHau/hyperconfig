#!/usr/bin/env python3
"""Generate the mechanical part of the hyperconfig-map agent skill.

    repo-map.py [--root DIR] [--out FILE] [--check]

Reads the repository as text (no Nix evaluation, stdlib only) and writes
skills/hyperconfig-map/references/map-*.md: machines and the files they
import, every module file with the first line of its header comment and
who imports it, declared options, clan vars generators, generated vars
per machine and the flake checks. --check compares with the committed
file instead and exits 1 when it is stale (the flake check repo-map runs
this). Only what changes when the layout changes is in the map (no line
numbers), so ordinary edits inside a module do not make it stale.
"""

import argparse
import os
import re
import sys
from collections import defaultdict

OUT_DIR = "skills/hyperconfig-map/references"
# file -> the sections (## headings) it holds
FILES = {
    "map-machines.md": ["Machines", "Flake checks"],
    "map-modules.md": ["Module index"],
    "map-options.md": ["Options declared", "Clan vars generators"],
}
SCAN_ROOTS = ["machines", "modules", "hyperhermes/modules", "tools", "flake.nix"]
SKIP_DIRS = {".git", ".jj", ".sbox", "__pycache__", "test-keys", "node_modules", ".direnv"}
PATH_RE = re.compile(r"(?<![\w$}])(\.\.?/[A-Za-z0-9_.+/-]+)")
OPTION_RE = re.compile(r"\boptions\.((?:[A-Za-z_][A-Za-z0-9_-]*\.)*[A-Za-z_][A-Za-z0-9_-]*)\s*=")
GEN_RE = re.compile(r"\bgenerators\.(\"[^\"]+\"|[A-Za-z0-9_-]+)\s*=")


def rel(root, path):
    return os.path.relpath(path, root).replace(os.sep, "/")


def walk(root, sub):
    top = os.path.join(root, sub)
    if os.path.isfile(top):
        yield top
        return
    for d, dirs, files in os.walk(top):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            yield os.path.join(d, f)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def header(text, limit=120):
    """First sentence of the leading comment (after an optional `{ args }:`)."""
    lines = text.splitlines()
    i = 0
    # skip a leading module argument header like `{ pkgs, lib, ... }:`
    if i < len(lines) and lines[i].lstrip().startswith("{") and "#" not in lines[i] and "/*" not in lines[i]:
        j = i
        while j < len(lines) and j < 12 and not lines[j].rstrip().endswith(":"):
            j += 1
        if j < len(lines) and lines[j].rstrip().endswith(":"):
            i = j + 1
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i >= len(lines):
        return ""
    s = lines[i].strip()
    parts = []
    if s.startswith("/*"):
        s = s[2:].strip()
        k = i
        while True:
            if "*/" in s:
                parts.append(s.split("*/")[0].strip())
                break
            if s:
                parts.append(s)
            k += 1
            if k >= len(lines) or len(" ".join(parts)) > limit:
                break
            s = lines[k].strip()
            if not s and parts:
                break
    elif s.startswith("#"):
        k = i
        while k < len(lines) and lines[k].strip().startswith("#"):
            t = lines[k].strip().lstrip("#").strip()
            if not t and parts:
                break
            if t:
                parts.append(t)
            if len(" ".join(parts)) > limit:
                break
            k += 1
    else:
        return ""
    out = " ".join(p for p in parts if p)
    m = re.search(r"^(.+?[.:;])(\s|$)", out)
    if m and len(m.group(1)) >= 25:
        out = m.group(1)
    out = out.replace("|", "/")
    if len(out) > limit:
        out = out[: limit - 1].rstrip() + "…"
    return out


def resolve(root, src, ref):
    """A relative path literal in src -> repo-relative target, or None."""
    p = os.path.normpath(os.path.join(os.path.dirname(src), ref))
    if not p.startswith(root):
        return None
    if os.path.isdir(p):
        if os.path.isfile(os.path.join(p, "default.nix")):
            return rel(root, os.path.join(p, "default.nix"))
        return rel(root, p) + "/"
    if os.path.isfile(p):
        return rel(root, p)
    return None


def module_files(root):
    """The files the module index lists, in order."""
    out = []
    for base in ["modules/nixos", "modules/clan", "modules/flake-parts", "hyperhermes/modules", "tools"]:
        for p in walk(root, base):
            r = rel(root, p)
            if r.endswith(".nix") or r.endswith(".sh") or r.endswith(".py") or r.endswith("SKILL.md"):
                if "/test-keys/" in r or "/tests/" in r:
                    continue
                if base == "tools" and r.endswith(".py") and "/repo-map/" not in r:
                    continue
                out.append(r)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    out_dir = os.path.join(root, a.out_dir or OUT_DIR)

    nix_files = [p for s in SCAN_ROOTS for p in walk(root, s) if p.endswith(".nix")]
    texts = {rel(root, p): read(p) for p in nix_files}

    importers = defaultdict(set)  # target -> files referencing it
    refs = defaultdict(list)  # file -> targets in order
    for r, t in texts.items():
        src = os.path.join(root, r)
        for line in t.splitlines():
            code = line.split("#", 1)[0] if not line.strip().startswith("#") else ""
            for m in PATH_RE.finditer(code):
                tgt = resolve(root, src, m.group(1))
                if tgt and tgt != r:
                    importers[tgt].add(r)
                    if tgt not in refs[r]:
                        refs[r].append(tgt)

    def who(target):
        """Importers, machine files folded to the machine name."""
        names = set()
        for f in importers.get(target, ()):
            m = re.match(r"machines/([^/]+)/", f)
            names.add(m.group(1) if m and f.endswith("configuration.nix") else f)
        machines = sorted(n for n in names if "/" not in n)
        files = sorted(n for n in names if "/" in n)
        return machines, files

    L = []
    w = L.append
    w("# hyperconfig map (generated)")
    w("")
    w("Generated by `tools/repo-map/repo-map.py` from the repo text (no eval);")
    w("`checks.x86_64-linux.repo-map` fails when it is stale. Regenerate:")
    w("`nix run .#repo-map` (or `python3 tools/repo-map/repo-map.py`). Grep this")
    w("file, don't read it whole. `<-` = files/machines that reference the path.")
    w("")

    # --- machines
    w("## Machines")
    w("")
    machines = sorted(d for d in os.listdir(os.path.join(root, "machines")) if os.path.isdir(os.path.join(root, "machines", d)))
    for m in machines:
        cfg = f"machines/{m}/configuration.nix"
        own = sorted(rel(root, p) for p in walk(root, f"machines/{m}") if not p.endswith(".json") and "/facts/" not in p)
        own = [o.split(f"machines/{m}/", 1)[1] for o in own if o != cfg]
        imps = [t for t in refs.get(cfg, []) if not t.startswith(f"machines/{m}/")]
        inputs = sorted(set(re.findall(r"inputs\.([A-Za-z0-9_-]+\.nixosModules\.[A-Za-z0-9_-]+)", texts.get(cfg, ""))))
        w(f"### {m}")
        w(f"- header: {header(texts.get(cfg, '')) or '-'}")
        w(f"- own files: {', '.join(own) if own else '-'}")
        w(f"- imports: {', '.join(i.replace('modules/nixos/', 'm/') for i in imps) if imps else '-'}")
        if inputs:
            w(f"- input modules: {', '.join(inputs)}")
        vdir = os.path.join(root, "vars/per-machine", m)
        if os.path.isdir(vdir):
            w(f"- vars generated: {' '.join(sorted(os.listdir(vdir)))}")
        w("")
    w("`m/` = modules/nixos/. Every inventory machine also gets what the clan")
    w("inventory (modules/flake-parts/nixosConfigurations.nix) adds; modules it names:")
    inv = [t for t in refs.get("modules/flake-parts/nixosConfigurations.nix", []) if t.startswith("modules/") or t.startswith("machines/")]
    w(", ".join(inv))
    w("")
    shared = os.path.join(root, "vars/shared")
    if os.path.isdir(shared):
        w(f"Shared vars generated (vars/shared): {' '.join(sorted(os.listdir(shared)))}")
        w("")

    # --- module index
    w("## Module index")
    w("")
    w("`path — header — <- importers`")
    w("")
    section = None
    for r in module_files(root):
        sec = "/".join(r.split("/")[:2]) if not r.startswith("hyperhermes/") else "hyperhermes/modules"
        if sec != section:
            section = sec
            w(f"### {sec}")
        t = texts.get(r) if r in texts else read(os.path.join(root, r))
        if r.endswith("SKILL.md"):
            dm = re.search(r"^description:\s*(.*)$", t, re.M)
            h = dm.group(1).strip()[:120] if dm else ""
        else:
            h = header(t)
        ms, fs = who(r)
        if r.endswith("/default.nix"):
            d = r[: -len("default.nix")]
            more_ms, more_fs = who(d)
            ms = sorted(set(ms) | set(more_ms))
            fs = sorted(set(fs) | set(more_fs))
        imp = ms + [f.replace("modules/nixos/", "m/") for f in fs]
        if len(imp) > 8:
            imp = imp[:8] + [f"+{len(imp) - 8}"]
        w(f"- {r} — {h or '-'}" + (f" <- {', '.join(imp)}" if imp else ""))
    w("")

    # --- options
    w("## Options declared in the repo (option -> file)")
    w("")
    opts = defaultdict(set)
    for r, t in texts.items():
        for m in OPTION_RE.finditer(t):
            name = m.group(1)
            if name.startswith(("options.", "config.")) or len(name) < 3:
                continue
            opts[name].add(r)
    for name in sorted(opts):
        w(f"- {name}: {', '.join(sorted(opts[name]))}")
    w("")

    # --- clan vars generators
    w("## Clan vars generators declared (generator -> file)")
    w("")
    gens = defaultdict(set)
    for r, t in texts.items():
        for m in GEN_RE.finditer(t):
            gens[m.group(1).strip('"')].add(r)
    for name in sorted(gens):
        w(f"- {name}: {', '.join(sorted(gens[name]))}")
    w("")

    # --- flake checks
    w("## Flake checks (checks.x86_64-linux.<name> -> source)")
    w("")
    flake = texts.get("flake.nix", "")
    blk = flake.split("flake.checks.x86_64-linux", 1)
    if len(blk) == 2:
        body = blk[1]
        hosts = re.search(r"genAttrs\s*\[([^\]]*)\]", body)
        if hosts:
            w(f"- toplevel builds: {' '.join(re.findall(r'\"([^\"]+)\"', hosts.group(1)))} (system.build.toplevel)")
        for m in re.finditer(r"^\s{8}([a-z0-9-]+)\s*=\s*\n?(?:.*\n){0,3}?.*?(\./[A-Za-z0-9_./-]+|\$\{inputs\.[a-z]+\}/[A-Za-z0-9_/-]+)", body, re.M):
            w(f"- {m.group(1)}: {m.group(2).removeprefix('./')}")
    for r, t in sorted(texts.items()):
        if r.startswith("modules/flake-parts/"):
            for m in re.finditer(r"checks(?:\.x86_64-linux)?\.([a-z0-9-]+)\s*=", t):
                w(f"- {m.group(1)}: {r}")
            for m in re.finditer(r"clan\.nixosTests\.([a-z0-9-]+)\s*=", t):
                w(f"- {m.group(1)} (clan test): {r}")
    w("")

    # split L into sections, then into files
    preamble, sections, cur = [], {}, None
    for line in L:
        if line.startswith("## "):
            cur = line[3:]
            sections[cur] = [line]
        elif cur is None:
            preamble.append(line)
        else:
            sections[cur].append(line)
    outputs = {}
    for fname, heads in FILES.items():
        body = []
        for h, lines in sections.items():
            if any(h.startswith(x) for x in heads):
                body += lines
        outputs[fname] = "\n".join(preamble + body).rstrip() + "\n"

    if a.check:
        stale = False
        import difflib

        for fname, content in outputs.items():
            path = os.path.join(out_dir, fname)
            try:
                old = read(path)
            except FileNotFoundError:
                old = ""
            if old != content:
                stale = True
                sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), content.splitlines(True), f"committed/{fname}", f"generated/{fname}", n=1))
        if stale:
            print(f"\nrepo-map: {rel(root, out_dir)}/map-*.md is stale; run `nix run .#repo-map` (or `python3 tools/repo-map/repo-map.py`) and commit it.", file=sys.stderr)
            sys.exit(1)
        print("repo-map: up to date")
        return
    os.makedirs(out_dir, exist_ok=True)
    for fname, content in outputs.items():
        with open(os.path.join(out_dir, fname), "w", encoding="utf-8") as f:
            f.write(content)
        print(f"repo-map: wrote {rel(root, os.path.join(out_dir, fname))} ({len(content)} bytes)")


if __name__ == "__main__":
    main()
