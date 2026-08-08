---
name: project-init
description: >
  Use when starting work in an empty or near-empty project directory, when
  scaffolding a new project, or when adding a new independent subproject
  to a monorepo. Triggers BEFORE any implementation effort begins.
---

# Project Init

Before writing any implementation code in a new project or subproject,
set up the environment. No ad-hoc toolchains, no globally installed
dependencies, no `pip install` / `npm -g` / rustup.

## Checklist

1. **Nix devShell, preferably via `flake.nix`.** All dependencies —
   compilers, interpreters, package managers, CLIs — come from the
   devShell. Add an `.envrc` with `use flake` (nix-direnv is active on
   this system) and run `direnv allow`. For a monorepo subproject,
   extend the existing flake's devShell(s) (e.g. a per-subproject
   `devShells.<name>`) instead of adding a second flake.
2. **Prefer nixpkgs-native package sets** over language-specific
   fetchers wrapped in Nix: `python3.withPackages`, `pkgs.nodePackages`
   / `buildNpmPackage`, `rustPlatform`, `pkgs.haskellPackages`,
   `pkgs.buildGoModule`, etc. Reach for third-party flake frameworks
   (poetry2nix, crane, dream2nix, …) only when nixpkgs genuinely cannot
   express the dependency.
3. **State-of-the-art linters for the stack, in the devShell.** Examples:
   - Python → `ruff` (lint + format), `mypy`
   - Shell → `shellcheck`, `shfmt`
   - Nix → `statix`, `deadnix`, `nixfmt` (or `alejandra`)
   - Rust → `clippy`, `rustfmt`
   - Go → `golangci-lint`
   - JS/TS → `biome` (or eslint + prettier if the ecosystem demands)

   **Stack not decided yet?** Defer this item explicitly — note it as an
   open task — and add the linters the moment the stack is chosen, not
   after code has accumulated.

## Red flags

- First commit contains source code but no `flake.nix` / devShell
- "I'll just use the system python for now"
- Stack was decided three commits ago and no linter is configured
