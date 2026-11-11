# som's hermes agents

Agents run natively on som via hyperhermes (`services.hyperhermes.agents.<name>`).

| file | holds |
|---|---|
| `machines/som/hermes-agents.nix` | per-agent entry: description, `sshKeys`, `teamclaude.enable`, `openrouter`, `mail.enable`, skillDirs; host-wide hermes settings; deny-ACL assertion |
| `machines/som/hermes-agents-data.nix` | plain data read by som AND vit: `<name>.uid` (+ `vault = false`) for agents with vault/GPU account |
| `machines/som/hermes-dashboards.nix` | agent -> pocket-id account (`accounts`), `domain` davhau.fyi, front door |
| `machines/som/hermes-inference.nix` | models/providers (p0 Qwen, auxiliary vision/titles) |
| `machines/som/configuration.nix` | `slotIds.<name>` (never reuse; 18 retired), `slotNames` (>11 chars), set `hermes-agents-data.nix // { roman = {}; ... }` for non-data agents |
| `modules/flake-parts/nixosConfigurations.nix` | pocket-id users (oidc instance, `roles.server.machines.edi.settings.users`), `groups = [ "hermes" ]`; clients derived via `hyperhermes.lib.sso.oidcClients` |
| `modules/nixos/vault-ids.nix` | uid ladder (header), `hyper.vaultIds.deniedUsers` for no-vault agents |
| `modules/nixos/hermes-agents-gpu-host.nix` | vit: one account per data-file agent, same uid |
| `modules/nixos/entity-storage/` | home datasets, derived from `services.hyperhermes.agents` (explicit entry only for a quota override) |
| `hyperhermes/modules/*` | core, dashboards, publish, slots, mail, teamclaude, browser; `hyperhermes/lib/sso.nix`, `lib/clan.nix` (generators) |

## Add an agent (copy the closest: `roman` = no vault, not on vit; a data-file agent = vault-ro, account on vit)

This list is complete (6 files); to answer "which files", don't re-derive
it, open only the one entry you copy from.

1. uid: next free in the `vault-ids.nix` header ladder (never reuse);
   into `hermes-agents-data.nix` (vault/vit agents) or the entry's `uid`.
2. `hermes-agents.nix`: the entry.
3. `hermes-dashboards.nix`: account mapping.
4. `nixosConfigurations.nix`: pocket-id user (only for a new person).
5. `configuration.nix`: `slotIds.<name>`; non-data agent also into the `//` set.
6. `vault-ids.nix`: ladder comment; no-vault agent into `deniedUsers`
   (som asserts it) + by hand on bam: `setfacl -m u:<uid>:--- /vault`.

Then generate only its generators (`hermes-agent-ssh-<n>`,
`teamclaude-hermes-<n>`, `oidc-client-hermes-<n>`, `mailgate-imap-<n>`):
list with `nix eval --json .#nixosConfigurations.som.config.clan.core.vars.generators --apply 'g: builtins.filter (n: builtins.match ".*<n>.*" n != null) (builtins.attrNames g)'`.
Deploy som + edi (pocket-id client) + vit (data-file agents). Welcome
message: `nix run .#hermes-onboard -- som <name>` (tools/hermes-onboard).

## Facts

- Host-wide `services.hyperhermes.settings` reach every agent on som.
- `teamclaude` client keys: `hyper.teamclaudeGateway.clientKeys` in
  hermes-agents.nix -> `modules/nixos/teamclaude-gateway/`.
- infra-space's own hermes is NOT here: `modules/nixos/infra-space/hermes.nix`
  (container, lockedConfig, skills via `nixSkills`).
