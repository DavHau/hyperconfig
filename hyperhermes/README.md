# hyperhermes

NixOS modules that run [hermes-agent](https://github.com/NousResearch/hermes-agent)
for several agents on one host: each agent in its own login account, with
its web dashboard, published ports, an optional container slot, web tools
and more behind one nginx and one OpenID Connect login. Options live under
`services.hyperhermes.*`; every secret is a runtime file path, never a
store path.

## Modules

`nixosModules.default` imports every feature module, each off until enabled.

| module | what it does |
|---|---|
| `core` | agent registry (`agents.<name>`: uid, keys, `secretEnv`, settings), the patched hermes package, gateway and dashboard units, owner-checked forwards, firewall |
| `exposure` | nginx routing by host name below `domain`; `mode = "local"` (HTTP on `127.0.0.1:8473`, `hermes.localhost`) or `"public"` (HTTPS, ACME DNS-01, `dnsRecords`) |
| `sso` | OIDC sign-in: the issuer, client secrets, which account owns which agent; local mode runs dex with password users |
| `dashboards` | each agent's hermes dashboard at `<agent>.<domain>`, group-checked, plus an optional front door |
| `publish` | ten ports per agent at `<port>.<agent>.<domain>`, private ones behind their own login |
| `slots` | a NixOS container per agent (`agents.<name>.slot`), reachable at `slot.<agent>.<domain>` |
| `container-slots` | the generic container-slot machinery `slots` builds on (`services.container-slots`) |
| `browser` | Camofox browser, web extract, SearXNG, captcha and OCR clients |
| `mail` | receive-only, sanitized mail per agent, read through a read-only IMAP CLI (public mode only) |
| `wallet` | one shared phoenixd Lightning wallet for agents with `wallet.enable` |
| `teamclaude` | an agent's Anthropic traffic through a TeamClaude gateway |
| `claude-auth` | Claude Pro/Max OAuth for the agents (vendored hermes-claude-auth) |
| `desktop` | the hermes-desktop app and TUI launchers on a workstation |
| `clan` | fills the secret paths from [clan](https://clan.lol) vars (not in `default`) |
| `local-container` | the whole local deployment in one NixOS container on a workstation (not in `default`) |

`lib` exports `sso.oidcClients` (the OIDC client list), `clan.*` (generator
names), `mkAgentSkill`, the per-agent constants (`stateDir`, ports, unit
names) and the Python venv helpers.

## Local quickstart

```nix
# flake inputs: hyperhermes.url = "github:…/hyperhermes";
{
  imports = [ inputs.hyperhermes.nixosModules.local-container ];
  services.hyperhermes.localContainer = {
    enable = true;
    config.services.hyperhermes.agents.alice = {
      uid = 1001;
      slot = { enable = true; id = 1; };
    };
  };
}
```

`nixosConfigurations.example` is this setup (`example/`). After the switch:

- password of the account `alice` (generated at the container's first boot):
  `sudo nixos-container run hyperhermes -- cat /var/lib/hyperhermes-local/dex/alice.password`
- dashboard: <http://alice.hermes.localhost:8473>, sign in as `alice@hermes.localhost`
- a port the agent serves on `127.0.0.1:30010`: <http://30010.alice.hermes.localhost:8473>
- the slot's port 80: <http://slot.alice.hermes.localhost:8473>; the agent drives
  its slot with the `slot` command (skill `container-slot`)

The container holds every secret below `/var/lib/hyperhermes-local`
(OIDC client secrets, dex passwords and their hashes, the published ports'
cookie secret, each agent's ssh key); delete a file (for a dex account its
`.password` or `.hash`) and restart `hyperhermes-local-secrets` to rotate
it. The agent's model provider is configured in hermes itself, or handed
in as a runtime file through `agents.<name>.secretEnv`. The host gets NAT
for the container's veth, which turns on IPv4 forwarding host-wide
(`networking.nat`); the container's web front accepts only the host's
veth address, so a LAN peer routing to the container's subnet through
the host gets no answer. The slots' IPv6 addresses are private there
(`slots.publicIPv6 = false`). Slots nest containers, so the host's
`/nix/store` must support idmapped mounts (ext4, btrfs, xfs, zfs).

## Public deployment

A host sets, besides its agents:

- `exposure = { enable = true; mode = "public"; domain = "agents.example.org"; publicIPv4 = …; publicIPv6 = …; acme = { dnsProvider = "porkbun"; credentialFiles = { … }; }; }`
  — `domain` is agent-controlled: never the deployment's own site.
- `sso = { enable = true; issuer = "https://id.example.com"; accounts.<agent> = "<account>"; clients.<id>.secretFile = …; }`;
  the issuer declares exactly the clients `inputs.hyperhermes.lib.sso.oidcClients { … }`
  returns (also readable as `sso.oidcClients`), with each agent's group
  `hermes-<agent>` given to its owner. `sso.authorizationEndpoint` defaults
  to pocket-id's `/authorize`.
- `dashboards.enable`, `publish = { enable = true; cookieSecretFile = …; }`, and
  any other feature.
- DNS: publish `exposure.dnsRecords` (a list of `{ name, type, value }`) in the zone.

## Clan

Import `nixosModules.clan` next to clan-core's NixOS module and the secret
paths fill themselves from these vars generators (names are the stored
secrets; `lib.clan` has the per-agent ones):

| generator | for |
|---|---|
| `hermes-agent-ssh-<agent>` | the agent's ssh key (`sshKeyFile`, slot deploy key) |
| `hermes-oauth2-proxy` | the front door's cookie secret |
| `hermes-serve-oauth2-proxy` | the published ports' cookie secret |
| `oidc-client-hermes-<agent>`, `oidc-client-hermes-serve` | restart units only; declared by whatever runs the clan's issuer |
| `mailgate`, `mailgate-imap-<agent>`, `mailgate-oauth2-proxy` | mail |
| `phoenixd-seed`, `phoenixd-api` | wallet |
| `teamclaude-hermes-<agent>` | TeamClaude client key (agents with `teamclaude.enable`) |
| `hermes-desktop-ssh` (shared) | the desktop app's ssh key |

## Checks

`nix flake check`: VM tests `core`, `local-sso`, `public`, `publish`,
`browser`, `wallet`, `mail`, `slots`, `slots-local`, `local-deployment`;
evaluation-only `client-features` and `clan-eval`.

## hermes patches

`core`'s package is upstream hermes v2026.9.14 with these wheel patches
(`modules/core/patches`; each file's header has symptom, cause and fix):

- `hermes-dashboard-oidc-allowed-groups`: the dashboard's OIDC login admits
  everyone the issuer vouches for; the patch checks the ID token's `groups`
  claim against `allowed_groups` at sign-in, refresh and every request. Needed
  because dex (and any issuer without per-client groups) would let every
  account into every dashboard. Upstream: NousResearch/hermes-agent#55648.
- `hermes-auth-bare-named-provider`: a bare named provider in `model.provider`
  left the dashboard on "Setup Required".
- `hermes-gateway-restart-foreign-unit`: `hermes gateway restart`/`stop`
  broke a gateway supervised by a unit not named `hermes-gateway*`
  (here `hermes-agent-<agent>`).
- `hermes-gateway-no-home-shutdown-broadcast`: no shutdown notice to every
  home channel on each restart.
- `hermes-camofox-browser-downloads`, `-solve-captcha`, `-vault`: downloads,
  captcha solving and the password vault with the Camofox browser backend.
- `hermes-hosted-ocr-url`: scanned-PDF OCR against a self-hosted endpoint
  (`browser.ocr.baseUrl`) instead of Firecrawl.
