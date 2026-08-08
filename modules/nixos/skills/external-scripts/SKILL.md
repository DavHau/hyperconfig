---
name: external-scripts
description: >
  Use when writing or embedding shell/bash or Python scripts anywhere —
  Nix modules (writeShellApplication, writeShellScript, writeScript),
  systemd units, CI configs, Dockerfiles, heredocs, or inline strings in
  another language. Applies whenever a script exceeds 10 lines.
---

# External Scripts

Any shell or Python script longer than 10 lines MUST live in its own file
and MUST pass a linter. Never embed it as an inline string in Nix, YAML,
JSON, or another language.

## Rules

1. **Separate file, next to the consumer.** E.g. `foo.nix` reads
   `foo.sh` via `builtins.readFile ./foo.sh`; a systemd unit references
   the script file; CI calls `./scripts/foo.sh`.
2. **Lint before yielding:**
   - shell → `shellcheck -s bash foo.sh` (via `nix shell nixpkgs#shellcheck`
     if not on PATH). `pkgs.writeShellApplication` also shellchecks at
     build time — still run shellcheck on the standalone file so editors
     and CI see it.
   - Python → `ruff check foo.py` (fallback: `python -m pyflakes`).
3. **≤10 lines may stay inline** (one-liners, tiny wrappers). Count real
   logic lines, not blanks/comments. When in doubt, extract.
4. **No escaping tax.** Extraction removes Nix `''${` escaping — the file
   contains plain `${var}` bash. Never keep an inline copy "for reference".

## Nix pattern

```nix
(pkgs.writeShellApplication {
  name = "my-tool";
  text = builtins.readFile ./my-tool.sh;   # plain bash, no '' escaping
})
```

The `.sh` file has no shebang (writeShellApplication adds it plus
`set -euo pipefail`); lint it with `shellcheck -s bash`.

## Red flags

- A `text = ''` block in Nix growing past 10 lines
- Heredoc scripts inside YAML/Dockerfiles
- "I'll extract it later" — extract now, lint now
