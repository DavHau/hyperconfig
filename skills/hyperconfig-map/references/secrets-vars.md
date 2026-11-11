# Clan vars, generators, secrets

- Backend: age, external store (`modules/flake-parts/nixosConfigurations.nix`
  `vars.settings`), encrypted repo DavHau/hyperconfig-secrets checked out
  at `~/clan-secrets` in infra-space; recipients
  `modules/nixos/infra-space/age-recipients.nix`. In this repo only public
  values: `vars/per-machine/<m>/<gen>/<file>/value`, `vars/shared/<gen>/`.
- Which generators exist: `grep -n <name> references/map-options.md`
  (declared -> file) or eval
  `.#nixosConfigurations.<m>.config.clan.core.vars.generators`.
- Generated ones per machine: `ls vars/per-machine/<m>` (also in map-machines.md).
- A generator: `clan.core.vars.generators.<g> = { files.<f> = { secret ?
  true; restartUnits = [..]; }; prompts.<p> = {..}; script = ''...''; runtimeInputs; share ? false; }`.
  Use `config.clan.core.vars.generators.<g>.files.<f>.path` for the
  runtime path (`/run/secrets/...`), `.value` for public ones.
- **restartUnits** do nothing in clan's age backend by themselves:
  `modules/nixos/clan-vars-restart-units.nix` (activation step, salted
  hashes in /run/clan-vars-restart-units, feeds
  `/run/nixos/activation-restart-list`; first switch after boot only
  records). Enabled fleet-wide by the `clan-vars-restart-units` importer
  instance in nixosConfigurations.nix. Test: `checks...clan-vars-restart-units`.
- Shared keys used by many modules: `inference-api-key.nix` (p0 token),
  `teamclaude-api-key.nix`, `iodine-password.nix`, porkbun (dyndns).
- Secrets mirror on every machine: `modules/nixos/clan-secrets-mirror.nix`.

Recipe, add a generator: declare it in the module that consumes it
(next to its use), `restartUnits` = consuming units; then (infra-space,
no prompts) `/run/current-system/sw/bin/clan vars generate <m> --generator <g> --no-sandbox`
and commit `vars/per-machine/<m>/<g>/` with the change. Prompted ones:
Dave runs the generate; never land them ungenerated (blocks all deploys).
