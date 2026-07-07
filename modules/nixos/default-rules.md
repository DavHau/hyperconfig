---
alwaysApply: true
---

## Bash Output

Do NOT pipe command output through `tail`, `head`, or similar truncation.

## Development Style

All implementation work is test-driven. Read the `tdd` skill
(`skill://tdd`) before you start implementing.

## Nix Build Timeout

Run all `nix build` (and related nix build commands) with a timeout of **120 seconds** by default.
If a build fails due to a timeout, retry with the timeout doubled (e.g. 120s → 240s → 480s → …).
Keep doubling on consecutive timeout failures until the build succeeds or fails for a non-timeout reason.

## Version Control

Use `jj` (Jujutsu) instead of `git` for all version control operations.

**Isolated subagents run no version control.** When you are an isolated
`task` subagent (running in a copy-on-write worktree), you MUST NOT run
`jj` or `git` at all — no `jj st`/`new`/`describe`, no `git
add`/`commit`/`rm`. Just edit files. The harness snapshots your worktree
and commits/merges your changes into the parent automatically; running
version control yourself corrupts that capture.

## Dependency Source Code

When you need to understand how any dependency works, always get its source code rather than guessing or relying on documentation alone.
1. First check `$HOME/projects/` for an existing checkout of the dependency.
2. If not found, clone the project into `$HOME/projects/` and read the source there.
3. Use the source code as the primary reference for understanding behavior, APIs, and internals.

## NixOS Module Organization

Always create new NixOS features as a separate `.nix` file in `modules/nixos/` and import it where needed.
Do NOT inline new features into existing files.

## Nix Store

**NEVER** run `find` on the top-level `/nix/store` directory. It contains millions of entries and will hang or time out. If you need to locate a file inside a specific store path, use the full store path (e.g. `find /nix/store/<hash>-<name>/`).

**NEVER** run `find` on `/` or other large filesystem roots. It will hang or time out. To locate source code or definitions, prefer in order:
1. `nix eval` (e.g. `nix eval --raw nixpkgs#<pkg>.src` or `nix eval .#nixosConfigurations.<host>.config.<path>`) to resolve store paths or config values.
2. `git` / `jj` (e.g. `git grep`, `git ls-files`) inside the relevant repo.
3. `$HOME/projects/<project>` checkouts — clone there if missing and search the source tree directly.

## Running Unavailable Programs

If a program is not currently installed, do NOT attempt to install it via `nix-env` or similar. Instead, use one of:
- `nix-shell -p <package> --run '<command>'`
- `nix shell nixpkgs#<package> -c <command>`
