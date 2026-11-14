# hyperconfig conventions

One mechanism, one module, one naming scheme. Before writing a module,
look the concern up in the Mechanisms index
(`skills/hyperconfig-map/SKILL.md`) and in
`skills/hyperconfig-map/references/map-options.md`. `checks.x86_64-linux.hygiene`
(`tools/hygiene/`) enforces the mechanical parts below against a baseline
of today's debt: new violations fail, old ones are paid down.

## Extend or create

- **A new instance is data in the existing module**: another disk, key,
  space, agent, metric or gated port is an attribute of the module that
  owns that mechanism, not a copy of it.
- **A new mechanism is a new module**: a new file in `modules/nixos/`,
  imported where needed. A second implementation of something the index
  lists needs a reason in the commit body ("why not extend X").
- Machine files (`machines/<m>/configuration.nix`) hold imports and plain
  settings for that machine; logic, generators and lists of things go into
  a module or a data file next to it. Budget ~250 lines (som is over:
  baseline, ratchet down).

## Modules

- Name `<area>-<thing>.nix` (`monitoring-zfs-pools`, `nix-cache`), the
  generic concept over a product or model name.
- A module becomes a directory `<name>/default.nix` once it has more than
  one file; its VM test is `<name>/test.nix` inside it (older flat
  `foo-test.nix` files are legacy).
- Every module starts with a header comment: what it does and why, then
  where the rest lives (`../x.nix`, the option users set). The first
  sentence is what `map-modules.md` shows.
- Paths in comments are real paths relative to the file (or
  repo-root paths like `modules/nixos/x.nix`); update them when moving
  files. The hygiene check flags dangling ones.
- Deleting is fine; git keeps history. Don't leave commented-out imports.

## Names

- Options: `hyper.<camelName>.*` for our modules (`hyper.daveDesktop.user`,
  `hyper.mullvadEgress`). `services.*` only for modules published for
  reuse (hyperhermes). Guest-side options of a container: `space.*`.
  Legacy, to migrate, never copy: top-level `infraSpace.*`,
  `clanSecretsMirror.*`, `niri.outputExtras`, `zfsKeylocationSync`.
- Clan vars generators: `<feature>-<what>` (`zfs-key`, `luks-tang`,
  `voice-gateway-ha`), per instance `<feature>-<instance>-<what>`
  (`space-<s>-forge-token`). Files inside: `key`, `token`, `passphrase`,
  `password`, `<x>.pub`. Generators are declared in modules, never in
  machine files.
  Legacy names (`openrouter`, `tang`, `porkbun`, `storagebox`, `nextcloud`,
  `hyprspace`, `teamclaude-nmm`, `vault-key`) stay: a rename means moving
  the secret in the same commit; **never rename or regenerate a var that
  guards a disk** (`zfs-key`, `luks-key`, `vault-key`, `*-tang`).
- systemd units, users and groups: the module's name (`exec-usage.service`,
  `entity-storage.service`), suffixed per instance (`<s>-forge-cli`).
- State: `/var/lib/<module>/`; runtime secrets/sockets `/run/<module>/`.

## Registries (take ids from here, never invent one)

| what | where |
|---|---|
| uids/gids (NFS vault, agents, spaces, apps) | ladder in `modules/nixos/vault-ids.nix` header |
| hermes agents on som (uid, owner) | `machines/som/hermes-agents-data.nix` |
| container slots | `slotIds` in `machines/som/configuration.nix` |
| spaces (index, sshPort, uid, proxyUid) | `modules/nixos/spaces/registry.nix` |
| isolated desktop apps (10.235.1 index) | `modules/nixos/dave-desktop/apps.nix` |
| subnets and LAN sites | `home-networks/sites.nix` |
| Dave's ssh keys | `modules/admin-ssh-keys.nix` (other people: `modules/nixos/users/<name>.nix`, agents' owners in `machines/som/hermes-agents.nix`; host keys `modules/github-host-keys.nix`, `modules/nixos/spaces/forge-host-keys.nix`) |

A retired id, port or index is listed as retired where it was claimed
and never reused. Paste no ssh key or uid literal outside its registry.

## When the hygiene check fails

Fix the violation. If it is deliberate and permanent, add a line with a
reason to `tools/hygiene/allowlist.txt`. Accepting new debt
(`python3 tools/hygiene/hygiene.py --update-baseline`) needs a reason in
the commit body. After fixing old debt, run `--update-baseline` to drop
the fixed entries. `nix run .#hygiene -- --report` lists everything.
