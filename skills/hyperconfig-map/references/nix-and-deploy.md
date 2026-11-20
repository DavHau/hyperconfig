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
  nas, built), `eval-<m>` (som vit edi sgp joy installer: drvPath only,
  builds nothing), VM/container tests (list: `references/map-machines.md` "Flake checks"),
  `repo-map` (this skill's maps are fresh), `hygiene` (CONVENTIONS.md
  lint against `tools/hygiene/baseline.txt`). `nix flake check --no-build`
  evaluates all (~1.5 min). Run one VM/container test only for module logic.

## Deploy (never from a subagent unless told)
- `clan machines update <m> --target-host root@<m>.d --build-host localhost`
  with the system wrapper `/run/current-system/sw/bin/clan`; builds and
  switches. `inventory.machines.<m>.deploy` in nixosConfigurations.nix.

## Nightly nixpkgs bump: `modules/nixos/infra-space/nixpkgs-bump.nix`
Timer + skill `nixpkgs-bump/SKILL.md`; pre-push guard
`nixpkgs-bump/guard.sh` (denylists `denied_paths` for files,
`denied_opts` for option words), its test `nixpkgs-bump/guard-test.nix`
(`checks...nixpkgs-bump-guard`), wrapper `nixpkgs-bump/guard.nix`.


## Security jobs: `modules/nixos/infra-space/security-jobs.nix`
Three agent jobs on the bump's runner (`agent-job.nix`), as the
unprivileged guest account `infra-jobs` (uid 1223, own locked hermes
agent, no push/fleet/age keys): `cve-watch`
(daily 02:30 +07), `hygiene-report` (Sat 03:30 +07),
`security-audit` (Sun 03:30 +07); each waits for the
bump and fleet-bump (After=, the bump's lock) and they share
`/run/agent-jobs/security.lock`. Runs (bump
too) get `-t terminal,file,todo,delegation,no_mcp` (allowlist: no
skill/memory tools, no MCP; terminal can still write files);
failures: OnFailure= notice, the brief (`infraSpace.agentJobs`),
`recurring-tasks/registry.nix` (stale task); a lost gateway turn is
followed and resumed (`agent-job-follow.sh`). Skills
`security-jobs/<job>/SKILL.md` (+ `policy.md`, `common.md` spliced in).
Helpers: `sec-job-guard` (`security-jobs/guard.sh`, check
`sec-job-guard`; both-side lock-out lines, movable inputs list, one
takedown a night), `sec-job-deploy` (pushed rev, one build, rollback
watchdog `/run/sec-deploy-ok`), `sec-collect`, `sec-job-push`
(the four privileged ones only via `sudo -n -u infra`), `sec-cve-feeds`
(NVD + GHSA, `watchlist.json`), `sec-job-nix`; hygiene = `nix run
.#hygiene -- --report`; decisions via the proxy `sec-job-decision --by
<job>` (`decided` / `add --needs-dave` / `notice`, see
`infra-space/decisions.nix`). Takedowns: `modules/nixos/security-takedown/`
(in common.nix; data in `takedowns.json`, only
`security.takedown.eligible` units, from `eligible.nix`). Package fixes:
`modules/nixos/security-fixes/overlays.nix` (+ `.patch` files), applied
fleet-wide by the fixed wrapper `security-fixes.nix`.
