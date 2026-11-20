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
| `flake.nix` | inputs; `flake.checks.x86_64-linux` (toplevels of amy bam cm-pi nas built, `eval-<m>` for som vit edi sgp joy installer evaluated only, VM/container tests, `hygiene`, `repo-map`) |
| `modules/flake-parts/nixosConfigurations.nix` | THE clan: inventory, machines' tags/deploy, service instances (users, sshd, nix-cache, oidc + **pocket-id users**, wireguard, monitoring, zerotier), `importer` instances adding modules to every machine |
| `modules/flake-parts/*.nix` | other flake outputs (apps, packages, devShells), auto-imported |
| `machines/<m>/configuration.nix` | per-machine imports and settings; other files there are that machine's own |
| `modules/nixos/*.nix`, `*/default.nix` | NixOS modules, imported explicitly by machines or by `dave.nix`/`common.nix` |
| `modules/nixos/common.nix` | every machine but the installer (fleet-wide defaults with `lib.mkDefault`) |
| `modules/nixos/dave.nix` | Dave's desktops/workstations: amy, som, vit (huge import list) |
| `modules/clan/<svc>/` | our own clan services (nix-cache incl. ncro, oidc/pocket-id, wireguard, remote-building, cctl) |
| `hyperhermes/` | own flake (input `hyperhermes`): hermes agent modules, `lib/` (mkAgentSkill, sso), `checks/` |
| `modules/nixos/infra-space/` | the fleet-admin container on som+amy and its hermes (skills, nightly bump, security jobs) |
| `modules/nixos/spaces/` | named agent spaces (geninf-space) |
| `machines/som/hermes-*.nix` | som's hermes agents |
| `vars/per-machine/<m>/<gen>/`, `vars/shared/<gen>/` | clan vars, public values only (secrets: external age store) |
| `tools/`, `pkgs/`, `docs/` | CLIs (hermes-onboard, repo-map, skill-bench), packages, design specs |

Machines: som (AM5 server: hermes agents, infra-space, spaces, builds),
amy (Dave's laptop, grmpf user, also infra-space), vit (laptop, GPU host
for agents), bam (vault NFS server, nextcloud, inference VM), edi (cloud:
pocket-id, grafana, zerotier controller), sgp (lends IPv4 to som), nas,
joy, cm-pi (aarch64, Home Assistant), installer.

## Mechanisms (concern -> THE module -> how to extend)

If a feature resembles a row, extend that module: a new instance is data
there, never a second copy (`CONVENTIONS.md`; a new mechanism needs a
reason in the commit body). Rows marked *dup* still have copies: extend
the named owner and leave the copies to their unification.

| concern | owner | how to extend |
|---|---|---|
| disk unlock (zfs/luks root, tang, remote unlock) | `modules/nixos/zfs-remote-unlock/`, `luks-unlock/` + `tang-client.nix` (servers, `clevisPolicy`), `clan-unlock/`, `unlock-target.nix`; *dup*: nas's own tang bind, bam's `vault-key` keyfile | import the backend for the disk type, set `hyper.tangClient.servers`; vars `zfs-key`/`zfs-tang` or `luks-key`/`luks-tang`; never regenerate or rename them |
| provider API keys for harnesses (afk/omp) | `modules/nixos/provider-keys.nix` (`hyper.providerKeys.<name>`) | a new provider = an entry there (`<name>-api-key` command, group of desktop user + `agent`, sbox bind, `roFiles`); reuse `openrouter/apikey` |
| textfile metrics -> Mimir | `modules/nixos/monitoring-zfs-pools.nix` (timer -> `.prom.tmp` -> mv, `/etc/alloy/*.alloy`); *dup*: `teamclaude-gateway/metrics.nix`, `exec-usage/` | follow zfs-pools' shape; alert rules `monitoring-alerts.nix` |
| per-owner loopback gate (`meta skuid`) on multi-tenant som | `modules/nixos/infra-space/default.nix` (`hyper.infraSpace` allow rules); *dup*: `spaces/host.nix`, `voice-gateway`, `zt-eu-lan-guard`, `mullvad-egress`, `nix-sandbox-strict`, hyperhermes `slots` | add a rule to the module guarding that port; any new 127.0.0.1 service on som gets one |
| containers for agents/people | spaces: `modules/nixos/spaces/` (`registry.nix` = one entry per space); infra-space: `modules/nixos/infra-space/`; agent slots: `hyperhermes/modules/container-slots.nix` (`slotIds` in som's config); GUI from a container: `space-gui/` | a new space = an entry in `spaces/registry.nix` + `spaces/<name>.nix`; never a new container kind |
| Dave's desktop apps and desktop user | `modules/nixos/dave-desktop/` (`hyper.daveDesktop.user`, amy: grmpf) | read `hyper.daveDesktop.user`, never `if users ? grmpf` |
| SSO / pocket-id clients and users | `hyperhermes/lib/sso.nix` (`oidcClients`: clients as data) -> `services.hyperhermes.sso.oidcClients` (`hyperhermes/modules/sso.nix`); oidc instance in `modules/flake-parts/nixosConfigurations.nix` (users, groups); `modules/clan/oidc/` | add a client through `lib.sso.oidcClients` / `services.hyperhermes.sso.oidcClients`; *dup*: `wyoming-local-speech/voices-sso.nix` |
| uid/gid registry | ladder in `modules/nixos/vault-ids.nix` header; agents `machines/som/hermes-agents-data.nix` | take the next free id from the ladder, list retired ones there |
| subnet / index / port registry | `home-networks/sites.nix` (subnet claims), `spaces/registry.nix` (10.235.0 index, sshPort), `dave-desktop/apps.nix` (10.235.1 index), som `slotIds` (10.43.<id>) | claim it in the registry file first, never reuse a retired one |
| ssh keys | Dave's: `modules/admin-ssh-keys.nix`; others: `modules/nixos/users/<name>.nix`, agent owners in `machines/som/hermes-agents.nix`; host keys `modules/github-host-keys.nix`, `spaces/forge-host-keys.nix` | import the registry file, never paste a key (`checks.hygiene` flags copies) |
| hermes agent onboarding on som | `references/hermes-agents.md` (6 files today), `tools/hermes-onboard` | follow that list; the planned single agent entry will replace it |
| secrets restarting their units | `modules/nixos/clan-vars-restart-units.nix` | set `restartUnits`; nothing else |
| fleet-wide defaults | `modules/nixos/common.nix` (`lib.mkDefault`) | add there, not per machine |
| self-heal (deploy guard, watchdogs, boot health; `selfheal` CLI) | `modules/nixos/self-heal/` (`hyper.selfHeal.*`, `/var/lib/selfheal`, `docs/self-heal.md`) | a new part = a file there + a `selfheal` subcommand; reuse `selfheal health` |
| substituters, cache keys | `modules/clan/nix-cache/` | its settings |

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
- printer/scanner (USB on bam, ipp-usb on localhost:60000): host
  `machines/bam/printer.nix` -> `modules/nixos/home-printer-host.nix`
  (CUPS queue `home` shared to the LAN, scan page
  `modules/nixos/scan-trigger/` -> `/vault/misc/scans/`); desktops' queue
  `modules/nixos/home-printer.nix` (amy vit joy); `docs/home-printer.md`.
- substituters, ncro, nix-cache keys: `modules/clan/nix-cache/default.nix`.
- nightly bump: `modules/nixos/infra-space/nixpkgs-bump{.nix,/}` (guard.sh
  denylists `denied_paths`/`denied_opts`; check `nixpkgs-bump-guard`).
  Timer/unit/verdict runner shared by all agent jobs: `infra-space/agent-job.nix`.
- security jobs (cve-watch daily 02:30, hygiene-report Sat 03:30,
  security-audit Sun 03:30, Asia/Bangkok; all wait for the bump's lock):
  `infra-space/security-jobs{.nix,/}` (Dave's policy + asking bar
  `policy.md`, shared rules `common.md`, guard + check `sec-job-guard`,
  decisions through the registry's `decision` CLI); takedowns as data
  in `modules/nixos/security-takedown/takedowns.json`.
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
  source): don't treat that as a behaviour change. Only som: no machine
  carries the commit (`hyper.agaveTunnel.reportRevision` would, on every
  commit; it is off).
- New *mechanism* = new file in `modules/nixos/` imported where needed;
  a new *instance* of an existing mechanism (Mechanisms table) is data in
  its module, not a copy (`CONVENTIONS.md`).
- `checks.x86_64-linux.hygiene` (`tools/hygiene/`, no eval) fails on new
  unimported modules, dangling paths, off-scheme generator names, pasted
  ssh keys and grown machine files; `nix run .#hygiene -- --report` lists
  all current ones.
- Exclude `.sbox/` from repo-wide greps (vendored state).
- After adding/moving/renaming a module or changing its header's first
  line: `nix run .#repo-map` and commit `skills/hyperconfig-map/references/map-*.md`
  (`checks.x86_64-linux.repo-map` fails otherwise).
