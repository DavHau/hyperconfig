# Spaces and infra-space (NixOS containers for agents)

## Named spaces: `modules/nixos/spaces/`

| file | holds |
|---|---|
| `registry.nix` | per space: `machine`, `index` (veth subnet 10.235.0.<4i>/30), `sshPort`, `uid`, `proxyUid` (ids also in the vault-ids.nix ladder) |
| `default.nix` | `hyper.spaces.<name>` options, host wiring, `credentials` (-> `/run/<name>/secrets/<cred>` in the guest), p0/TeamClaude keys; header = full design |
| `host.nix` | host side per space: veth, NAT, `confine`, sshd socket proxy, restart vs switch-in-place |
| `guest.nix`, `guest-base.nix` | the guest system (base shared with infra-space) |
| `<space>.nix` (geninf-space) | the space's own generators (`space-<name>-*`), credentials, repos cloned, forges |
| `forges.nix` | `space.forges.<host>` -> tea logins; `<name>-forge-cli.service` writes tea's config from the credential to `/run/<name>/tea/tea/config.yml` (tmpfs); skill `forge-prs-skill/` |
| `afk.nix` | afk in a guest: pinned settings (no web), keys from secretsDir |
| `client.nix` | Dave's desktops: launchers, pinned host keys, herdr machines |
| `public.nix` | registry + mesh addresses (no other machine's config) |
| `test.nix` | `checks.x86_64-linux.spaces` (VM test; names machines: grep it on moves) |

Token path, e.g. geninf-space: prompted generator `space-geninf-space-token-geninf`
(geninf-space.nix) -> `hyper.spaces.geninf-space.credentials.token-geninf` -> nspawn
credential -> `/run/geninf-space/secrets/token-geninf` -> forge-cli service ->
tea config on tmpfs.

Recipes:
- New space: registry entry (next index/port/uids, ladder in vault-ids.nix),
  `<name>.nix` with generators, import in `default.nix`'s list, generate
  `space-<name>-hostkey` before landing.
- Move: registry `machine`, `clan vars cp <old> <new> <gen>/<file>`, tar
  `/var/lib/spaces/<name>`, grep test.nix for the old machine.
- Rename: never regenerate keys; move values to the new generator names.
- Guest-only change: switches in place; credential/bind/nspawn change:
  restarts the container.

## infra-space: `modules/nixos/infra-space/`

Fleet-admin container on `members.nix` (som, amy; sshPort 2223).
`default.nix` host side, `guest.nix` guest (clan wrapper, secrets store
`~/clan-secrets`), `hermes.nix` its hermes (toolsets, `nixSkills`:
infra-space + nixpkgs-bump + hyperconfig-map; skills disabled list),
`hermes-skill/SKILL.md` the orchestrator skill, `nixpkgs-bump.nix` +
`nixpkgs-bump/` (SKILL.md, guard.sh), `dashboard.nix` (som),
`fleet-access.nix` (its root key on every machine), `age-recipients.nix`,
`gcroots.nix`, `launchers.nix` (Dave's desktops), `test.nix`
(`checks...infra-space`).
