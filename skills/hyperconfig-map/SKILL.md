---
name: hyperconfig-map
description: "Use when working in hyperconfig. Where things live, lookups, recipes."
---

# hyperconfig map

Dave's clan-based NixOS fleet. Paths are repo-relative.

## Look up, don't survey

1. **Grep the generated maps** in `skills/hyperconfig-map/references/`
   (repo path; also `skill_view` file_path), never read them whole:
   - `map-machines.md`: machine -> own files, imported
     modules, vars generated; the flake checks and their sources.
   - `map-modules.md`: every module file, its header's first
     sentence, who imports it (`<- som, m/dave.nix`).
   - `map-options.md`: option declared -> file; clan vars
     generator -> file.
   E.g. `grep -n 'ncro\|nix-cache' skills/hyperconfig-map/references/map-*.md`.
2. **Read the module's header comment** (what, why, where the rest
   lives) before the code; it often answers the question.
3. **Ask the evaluator** for effective values and who sets them (~1 s
   cached, ~15 s per machine cold):
   ```
   nix eval .#nixosConfigurations.<m>.config.<opt>
   nix eval --json .#nixosConfigurations.<m>.options.<opt>.definitionsWithLocations \
     --apply 'map (d: d.file)'      # every file that sets it
   nix eval --json .#nixosConfigurations.<m>.options.<opt>.declarations
   nix eval --json .#nixosConfigurations.<m>.config.clan.core.vars.generators --apply builtins.attrNames
   nix eval --json .#nixosConfigurations --apply builtins.attrNames
   ```
   For an attrset option (`nix.settings`), filter the definitions:
   `--apply 'o: map (d: d.file) (builtins.filter (d: d.value ? connect-timeout) o.definitionsWithLocations)'`.
   `/nix/store/...-source/<path>` = repo path (or an input's).
4. One area in depth: load the matching reference below, only that one.

Cost rule: every tool call resends the whole context. Batch lookups into
one `terminal` call (`grep -n -A3 ... ; sed -n 'a,bp' file`), grep with
context instead of reading whole modules, and when this skill or a map
line already states a fact, confirm it with at most one grep and move on.

## Layout

| path | what |
|---|---|
| `flake.nix` | inputs; `flake.checks.x86_64-linux` (toplevels of amy bam cm-pi nas, VM tests) |
| `modules/flake-parts/nixosConfigurations.nix` | THE clan: inventory, machines' tags/deploy, service instances (users, sshd, nix-cache, oidc + **pocket-id users**, wireguard, monitoring, zerotier), `importer` instances adding modules to every machine |
| `modules/flake-parts/*.nix` | other flake outputs (apps, packages, devShells), auto-imported |
| `machines/<m>/configuration.nix` | per-machine imports and settings; other files there are that machine's own |
| `modules/nixos/*.nix`, `*/default.nix` | NixOS modules, imported explicitly by machines or by `dave.nix`/`common.nix` |
| `modules/nixos/common.nix` | every machine but the installer (fleet-wide defaults with `lib.mkDefault`) |
| `modules/nixos/dave.nix` | Dave's desktops/workstations: amy, som, vit (huge import list) |
| `modules/clan/<svc>/` | our own clan services (nix-cache incl. ncro, oidc/pocket-id, wireguard, remote-building, cctl) |
| `hyperhermes/` | own flake (input `hyperhermes`): hermes agent modules, `lib/` (mkAgentSkill, sso), `checks/` |
| `modules/nixos/infra-space/` | the fleet-admin container on som+amy and its hermes (skills, nightly bump) |
| `modules/nixos/spaces/` | named agent spaces (geninf-space) |
| `machines/som/hermes-*.nix` | som's hermes agents |
| `vars/per-machine/<m>/<gen>/`, `vars/shared/<gen>/` | clan vars, public values only (secrets: external age store) |
| `tools/`, `pkgs/`, `docs/` | CLIs (hermes-onboard, repo-map, skill-bench), packages, design specs |

Machines: som (AM5 server: hermes agents, infra-space, spaces, builds),
amy (Dave's laptop, grmpf user, also infra-space), vit (laptop, GPU host
for agents), bam (vault NFS server, nextcloud, inference VM), edi (cloud:
pocket-id, grafana, zerotier controller), sgp (lends IPv4 to som), nas,
joy, cm-pi (aarch64, Home Assistant), installer.

## Where concerns live (one line each)

- afk/omp defaults: `modules/nixos/afk.nix` (`hyper.afk.defaultModel`,
  patched into afk's distro config `OMP_DISTRO_CONFIG` = layer below the
  user's config.yml; `pinnedSettings` = `PI_CONFIG_FILES` overlay above);
  shared omp bits `omp-common.nix`; spaces' afk `spaces/afk.nix`.
- space credentials/forge tokens: `modules/nixos/spaces/<space>.nix`
  (generator `space-<s>-*` -> `credentials`) -> `spaces/default.nix`
  (nspawn credential, `/run/<s>/secrets/`) -> `spaces/forges.nix`
  (`<s>-forge-cli.service` writes tea's config on tmpfs).
- secrets restartUnits with the age backend:
  `modules/nixos/clan-vars-restart-units.nix` (activation step; enabled
  for all machines as an `importer` instance in nixosConfigurations.nix).
- ids/uids ladder: header of `modules/nixos/vault-ids.nix`; hermes agent
  uids `machines/som/hermes-agents-data.nix`; slot ids
  `machines/som/configuration.nix` (`slotIds`); spaces
  `modules/nixos/spaces/registry.nix` (port, uid, proxyUid, index).
- per-user home datasets: `modules/nixos/entity-storage/default.nix`
  (`hyper.entityStorage`; entity-storage.service, wantedBy sysinit.target
  + sysinit-reactivation.target, before systemd-tmpfiles-setup/-resetup
  and user sessions: at boot and on every switch that changes it). som's
  users are derived from `services.hyperhermes.agents`.
- substituters, ncro, nix-cache keys: `modules/clan/nix-cache/default.nix`.
- nightly bump: `modules/nixos/infra-space/nixpkgs-bump{.nix,/}` (guard.sh
  denylists `denied_paths`/`denied_opts`; check `nixpkgs-bump-guard`).
- skills shipped to agents: infra-space `infra-space/hermes.nix`
  (`nixSkills`), som agents `machines/som/hermes-agents.nix` (`skillDirs`),
  afk `hyper.afk.extraSkills`, personal `modules/nixos/skills/`.

## References (load one when the task is in that area)

- `references/hermes-agents.md`: som's agents: files to touch, ids, vault, SSO.
- `references/spaces.md`: spaces + infra-space: registry, credentials, forges.
- `references/secrets-vars.md`: clan vars, generators, age store, restartUnits.
- `references/nix-and-deploy.md`: nix settings, cache/ncro, checks, deploy, bump.
- `references/afk-omp.md`: afk/omp config layers, models, skills in spaces.

## Pitfalls

- A new generator (prompted or not) blocks every deploy until generated.
- som's toplevel drvPath changes on any repo edit (nginx references the
  source): don't treat that as a behaviour change.
- New module = new file in `modules/nixos/` imported where needed; don't
  inline features into existing files (repo rule).
- Exclude `.sbox/` from repo-wide greps (vendored state).
- After adding/moving/renaming a module or changing its header's first
  line: `nix run .#repo-map` and commit `skills/hyperconfig-map/references/map-*.md`
  (`checks.x86_64-linux.repo-map` fails otherwise).
