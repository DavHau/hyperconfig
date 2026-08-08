# fast-nix-gc: prune stale gcroots/auto entries under --delete-older-than

Approved 2026-08-08.

## Problem

`gcroots/auto` accumulates indirect roots forever: nix-direnv devshells of
abandoned projects and old `nix build` `result` links keep multi-GB closures
alive. fast-nix-gc (like nix-collect-garbage) only removes *dangling* auto
links; age is never considered.

## Semantics

When `--delete-older-than SPEC` is given, additionally prune symlinks in
`<state-dir>/gcroots/auto`:

1. **devshell roots** — target path contains a `/.direnv/` component:
   stale if the newest atime/mtime across the project's `.direnv/*.rc`
   files is older than SPEC. nix-direnv sources the cached rc on every
   load, so under relatime its atime tracks last load at day granularity;
   under noatime this degrades to last rebuild (documented). No `.rc`
   files: fall back to the auto link's own mtime.
2. **all other auto roots** (`result` links, profile registrations…):
   stale if the auto link's own mtime is older than SPEC.
3. Dangling links: unchanged (already removed during root discovery).

`-d`/`--delete-old` without a time spec never prunes roots. `--dry-run`
logs "would remove" and touches nothing.

Opt-outs (both given restores old generations-only behavior):

- `--no-prune-devshell-roots` — skip class 1
- `--no-prune-auto-roots` — skip class 2

## Placement

New `crates/gc/src/auto_roots.rs`, called from `main.rs` directly after
`profiles::remove_old_generations`, before DB open and root discovery, so
pruned links never register as roots in the same run.

NixOS/darwin module (`nix/service-options.nix`): `deleteOlderThan` gains
the behavior; new boolean options `pruneDevshellRoots` / `pruneAutoRoots`
(default `true`) map to the `--no-*` flags when `false`.

## Risk

Diverges from `nix-collect-garbage --delete-older-than` (which never
touches auto roots). Owner may request opt-in instead of opt-out; the
default is a one-line flip.

## Tests (crates/gc/tests/integration.rs, TestStore)

- devshell root with old `.rc` times → pruned, store path collected
- devshell root with old mtime but fresh atime (File::set_times) → kept
- non-direnv auto root: old link mtime → pruned; recent → kept
- `--no-prune-devshell-roots` / `--no-prune-auto-roots` respected
- `--dry-run` removes nothing
- `--delete-old` without SPEC prunes nothing
