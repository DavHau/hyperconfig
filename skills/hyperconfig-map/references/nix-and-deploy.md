# Nix settings, binary caches, checks, deploy

## Nix settings
- Fleet defaults: `modules/nixos/common.nix` (max-jobs, features) and
  `nix.nix`, `nix-*.nix` in modules/nixos (gc, sandbox-strict on som,
  parallel-downloads, ssh client, registry). clan's own defaults come from
  clan-core (`nixosModules/clanCore/nix-settings.nix`).
- Who sets a nix setting: `nix eval --json .#nixosConfigurations.<m>.options.nix.settings --apply 'o: map (d: d.file) (builtins.filter (d: d.value ? <key>) o.definitionsWithLocations)'`.

## Binary caches: `modules/clan/nix-cache/default.nix` (clan service)
- `roles.server` (amy som vit bam): serves the store signed with the
  per-machine key `nix-cache-<instance>`.
- `roles.client` (all): local **ncro** proxy on 127.0.0.1:37515 as first
  substituter: `services.ncro.settings.upstreams` (peers priority 5,
  `narinfo_timeout = "1s"`; public caches priority 20),
  `cache.mass_query.per_upstream_max_inflight = 64`,
  `max_concurrent_races = 256`, `upstream_cooldown = "60s"`, fallback
  cache.nixos.org; `nix.settings.connect-timeout = lib.mkOverride 90 15`.
- Inventory instance `nix-cache` in nixosConfigurations.nix; ncro input
  `inputs.ncro` (flake.nix).
- Remote builders: `modules/clan/remote-building/` (som builds for amy).

## Checks
- `flake.checks.x86_64-linux` in `flake.nix`: toplevels (amy bam cm-pi
  nas), VM tests (list: `references/map-machines.md` "Flake checks"),
  `repo-map` (this skill's maps are fresh). `nix flake check --no-build`
  evaluates all (~1.5 min). Run one VM test only for module logic.

## Deploy (never from a subagent unless told)
- `clan machines update <m> --target-host root@<m>.d --build-host localhost`
  with the system wrapper `/run/current-system/sw/bin/clan`; builds and
  switches. `inventory.machines.<m>.deploy` in nixosConfigurations.nix.

## Nightly nixpkgs bump: `modules/nixos/infra-space/nixpkgs-bump.nix`
Timer + skill `nixpkgs-bump/SKILL.md`; pre-push guard
`nixpkgs-bump/guard.sh` (denylists `denied_paths` for files,
`denied_opts` for option words), its test `nixpkgs-bump/guard-test.nix`
(`checks...nixpkgs-bump-guard`), wrapper `nixpkgs-bump/guard.nix`.
