# Remote Building via Clan Service + Noctalia Toggle

Date: 2026-07-22
Status: approved design, pending implementation

## Goal

Offload nix builds from laptops to powerful clan machines. First instance:
`amy` (client) builds on `bam` (builder). A noctalia bar icon on the client
toggles remote building on/off at runtime. All authentication — ssh user
keys and nix store signing keys — is generated, deployed, and distributed
by clan vars; zero manual key handling.

## Non-Goals

- Builder reachability probing / automatic failover to local builds
  (the bar toggle IS the manual failover).
- Serving bam's store as a binary cache (separate, existing `nix-cache`
  module).
- Auto re-signing of the client store on a schedule (one-time manual step,
  see Deploy Notes).

## Architecture

```
amy (roles.client)                        bam (roles.builder)
──────────────────                        ───────────────────
vars: ssh keypair ───public key──────────▶ nixremote authorized_keys
vars: signing keypair ─public key────────▶ nix.settings.trusted-public-keys
nix.settings.secret-key-files             (nixremote is NOT a trusted-user)
nix.distributedBuilds = true
builders = @/run/remote-builders/machines
        ▲
remote-builders.service (oneshot, RemainAfterExit, enabled)
  start → writes machines file            noctalia CustomButton
  stop  → truncates it            ◀────── toggle script (polkit-allowed
                                           systemctl start/stop for wheel)
```

Host key trust needs no work: the existing clan-core `sshd` instance
(roles server+client on `tags.all`) already gives every machine a
CA-signed host certificate that clients trust for `*.d`.

## Components

### 1. Clan service `modules/clan/remote-building/default.nix`

`_class = "clan.service"`, `manifest.name = "hyperconfig/remote-building"`.
Generic: any number of builders and clients per instance.

#### roles.client — perInstance nixosModule

- **Vars generator `remote-building-<instanceName>`** (per-machine, not
  shared):
  - `files.ssh.id` (secret, deployed, root-owned 0400) +
    `files.ssh.id.pub` (public, in-repo): `ssh-keygen -t ed25519`.
  - `files.signing.key` (secret, deployed) + `files.signing.key.pub`
    (public, in-repo): `nix key generate-secret --key-name
    <machine>-remote-building-<instance>-1` / `nix key convert-secret-to-public`.
- **Signing:** `nix.settings.secret-key-files = [ <signing.key path> ]` —
  every locally built/added path is signed at registration time.
- **SSH transport:** no global root `programs.ssh` `Host` block — that
  would redirect interactive `ssh <builder>.d` for every user. Instead,
  each builder gets an entry in `nix.buildMachines` carrying
  `sshUser = "nixremote"` and `sshKey = <ssh.id path>`, so the
  credentials live in the machines file itself.
- **Protocol:** `protocol = "ssh-ng"`. Required: over the legacy ssh
  (serve) protocol, `build-remote` assumes the remote user is trusted
  and calls `buildDerivation`, which the builder's daemon rejects for
  untrusted users on input-addressed derivations. ssh-ng runs
  `nix daemon --stdio` on the builder, which accepts a signed closure
  upload + `buildPaths` from an untrusted user — exactly this trust
  model.
- **Distributed builds:**
  - `nix.distributedBuilds = true`,
    `nix.settings.builders-use-substitutes = true`.
  - `nix.buildMachines` renders the static `/etc/nix/machines`;
    `nix.settings.builders = "@/run/remote-builders/machines"` points
    the daemon at a runtime-switchable copy. nix-daemon re-reads the
    `@file` per build — toggling needs no daemon restart.
- **Toggle unit `remote-builders.service`:** oneshot,
  `RemainAfterExit = true`, `wantedBy = [ "multi-user.target" ]`
  (⇒ ON at boot, per decision). ExecStart installs the rendered machines
  file at `/run/remote-builders/machines` (0444, dir 0755); ExecStop
  truncates it. `systemctl is-active remote-builders` is the single
  source of truth for toggle state.
- **Polkit rule:** members of `wheel` may `start`/`stop`/`restart` exactly
  `remote-builders.service` without authentication
  (`org.freedesktop.systemd1.manage-units` scoped to that unit).
- **Interface options (client):** `barToggle : bool` (default `false`) —
  when true, imports the noctalia widget module (component 3). Set only
  for amy.

#### roles.builder — perInstance nixosModule

- **User:** `users.users.nixremote`: normal user, `isNormalUser = true`,
  default shell (ssh-ng runs `nix-daemon --stdio` through the login
  shell, so `nologin` would break it), no extra groups,
  `hashedPassword = "*"` — password unusable but account not locked:
  sshd with `UsePAM = false` rejects pubkey auth for locked (`!`)
  accounts.
- **Authorized keys:** for each machine in `roles.client.machines`, read
  `${clan.core.settings.directory}/vars/per-machine/<client>/remote-building-<instanceName>/ssh.id.pub/value`
  into `users.users.nixremote.openssh.authorizedKeys.keys`.
- **Signature trust:** for each client, read
  `.../signing.key.pub/value` into `nix.settings.trusted-public-keys`.
  **`nixremote` is NOT added to `nix.settings.trusted-users`** — unsigned
  path injection from a compromised client key is rejected; only paths
  signed by a registered client key (or upstream caches bam already
  trusts) are accepted.
- **Interface options (builder):**
  - `maxJobs : int` (default 10)
  - `speedFactor : int` (default 2)
  - `systems : listOf str` (default `[ "x86_64-linux" "aarch64-linux" ]`)
  - `supportedFeatures : listOf str` (default
    `[ "nixos-test" "big-parallel" "kvm" "benchmark" ]`)

  These are builder-side settings consumed by the *client* role when
  rendering its machines file (read via `roles.builder.machines.<name>.settings`).

### 2. Inventory + registration

In `modules/flake-parts/nixosConfigurations.nix`:

- `modules.remote-building = ../../modules/clan/remote-building;`
- Instance:

  ```nix
  remote-building = {
    module.name = "remote-building";
    module.input = "self";
    roles.builder.machines.bam = {};
    roles.client.machines.amy.settings.barToggle = true;
  };
  ```

Cleanup: delete the dead commented `nix.buildMachines` block in
`modules/nixos/laptop-dave.nix` (lines ~108–115).

### 3. Noctalia bar toggle `modules/nixos/noctalia-remote-build/`

No QML plugin — uses noctalia's built-in **CustomButton** widget.

- **`remote-build-toggle` script** (in `environment.systemPackages`):
  - `status`: prints CustomButton JSON on one line, e.g.
    `{"icon":"cloud-upload","tooltip":"Remote builds: on (bam)"}` when
    `remote-builders.service` is active,
    `{"icon":"cloud-off","tooltip":"Remote builds: off"}` otherwise.
    Icon names are noctalia's Tabler set (hyphenated); Material-style
    underscore names (`cloud_upload`) silently render a fallback glyph.
  - `toggle`: `systemctl stop` if active else `start` (passwordless via
    the polkit rule).
- **Config seeding:** an append-only merge script run as
  `systemd.user.services.noctalia-shell.serviceConfig.ExecStartPre`
  (`lib.mkAfter`, same slot and idempotence contract as
  `noctalia-anthropic-usage/merge.sh`): if no CustomButton with our
  command exists in `bar.widgets.right`, insert
  `{ id: "CustomButton", icon: "cloud-upload",
     leftClickExec: "remote-build-toggle toggle",
     textCommand: "remote-build-toggle status",
     parseJson: true, textIntervalMs: 3000 }`
  immediately BEFORE the `ControlCenter` widget (the noctalia owl stays
  the rightmost icon), or append when no ControlCenter is present.
  User's own layout and existing widgets are never rewritten; the merge
  is idempotent across restarts. `restartTriggers` on the merge script.

### 4. Clan test

Uses the **current clan-core test harness** (verified against clan-core
2026-07-21, the pinned input; local checkout `../clan/clan-core` at
2026-07-20 is equivalent):

- **Layout:** only `modules/clan/remote-building/tests/vm/default.nix` is
  committed, with `clan.directory = ./.`. **No committed `vars/` or
  `sops/` fixtures and no `update-vars` step** — the `clanTest` module
  (`lib/clanTest/flake-module.nix`) runs all vars generators at eval time
  via its Nix vars-executor and points `clan.core.settings.directory` at
  the merged result. Our generators are plain `ssh-keygen` / `nix key`
  scripts, so they run fine inside the executor derivation. (The
  committed-vars layout in `modules/clan/wireguard/tests/vm` is the
  legacy pattern; recent upstream services — `p2p-ssh-iroh`,
  `borgbackup` — commit only `default.nix`.)
- **Containers, not VMs:** the harness defaults to
  `clan.test.useContainers = true` (systemd-nspawn; far cheaper).
  Requires the `uid-range` system feature (`auto-allocate-uids`,
  `cgroups`) on the building host. Risk: assertion 4 runs nested nix
  builds inside a node — likely needs `nix.settings.sandbox = false` on
  the test nodes; if container nesting still fights the daemon, set
  `clan.test.useContainers = false` for this one test (documented
  fallback, decided by first implementation run).
- **Wiring into checks:** a new flake-parts module
  `modules/flake-parts/clan-tests.nix` (auto-imported by
  `all-modules.nix`):

  ```nix
  { inputs, ... }: {
    imports = [ inputs.clan-core.flakeModules.testModule ];
    perSystem = _: {
      clan.nixosTests.remote-building = {
        imports = [ ../clan/remote-building/tests/vm/default.nix ];
        clan.modules.remote-building = ../clan/remote-building;
      };
    };
  }
  ```

  `testModule` (exported, flagged "unstable interface" upstream) provides
  the `perSystem` `clan.nixosTests.*` option and exposes each test as
  `checks.<system>.remote-building` automatically. The test inventory
  references the module as `module.name = "remote-building";
  module.input = "self"` (mirrors upstream `borgbackup` test).
  Note: the dormant wireguard `flake-module.nix` stays untouched, but
  once this module exists its test could be registered the same way.
- **Nodes:** `builder1`, `client1`, one `remote-building` instance;
  node-level extras kept minimal (upstream pattern: harness injects
  minify + age-secrets modules via `defaults`).
- **Debugging:** `nix run .#checks.x86_64-linux.remote-building.driver
  -- --interactive` when on VMs; container runs log an `nsenter` command
  per node.
- **Assertions (the contract, in order):**
  1. `remote-builders.service` active at boot on client1;
     `/run/remote-builders/machines` non-empty and names
     `ssh://nixremote@builder1`.
  2. `systemctl stop remote-builders` → machines file empty;
     `start` → content restored (toggle round-trip).
  3. Root on client1 can `ssh -o BatchMode=yes nixremote@builder1 true`
     using only deployed vars (auth chain: CA host cert + generated
     user key).
  4. End-to-end offloaded build: client1 runs
     `nix build --expr` on a trivial derivation with
     `--max-jobs 0` (forces remote); assert the output path exists on
     client1 and the build log mentions the builder. This exercises the
     full signing chain: client-signed input paths accepted by builder's
     daemon WITHOUT `trusted-users`, and copy-back to the client.
  5. Negative: `nixremote` must remain genuinely untrusted. Implemented
     as a config-level assertion — builder1's
     `nix.settings.trusted-users` must not contain `nixremote` — rather
     than a runtime unsigned-push probe: `secret-key-files` on the
     client signs every local registration, so an unsigned path cannot
     be constructed client-side to push; assertion 4 already proves
     signatures are what the builder accepts.

## Security Model

| Threat | Mitigation |
| --- | --- |
| Client key compromise → root on builder | `nixremote` is unprivileged, not in `trusted-users`; ssh key grants only store-protocol access |
| Malicious store path injection into builder | Builder requires signatures from per-client keys in `trusted-public-keys`; revocation = remove one client's vars + redeploy |
| MITM on first connect | clan-core sshd CA host certificates (already deployed clan-wide) |
| Non-wheel local user flips builds | polkit rule scoped to `wheel` and to the single unit |

Accepted residual: a client signing key is trusted for *any* import on
the builder (including substitution), not only builds — narrower than
`trusted-users`, acceptable for this clan.

## Error Handling

- Builder unreachable while toggled ON: nix stalls/retries on the remote;
  user flips the bar icon OFF and rebuilds locally. No auto-probing.
- Copy-back signature check: the client daemon imports build results from
  the builder itself (build-hook path, no signature requirement on
  self-initiated copies). If implementation proves otherwise, symmetric
  fix: builder role also generates a signing key, clients trust it. The
  e2e test assertion 4 settles this.
- Unsigned pre-existing client paths: rejected as build inputs until the
  one-time re-sign (Deploy Notes).

## Deploy Notes (one-time, after first deploy to amy)

```sh
sudo nix store sign --all -k /run/secrets/vars/remote-building-remote-building/signing.key   # actual var path per clan vars layout
```

Signs pre-existing locally-built paths so they are accepted as build
inputs by bam. New builds are signed automatically.

## Verification Plan

1. `nix build .#checks.x86_64-linux.remote-building` (the clan test).
2. Eval both machines: `nix build .#nixosConfigurations.{amy,bam}.config.system.build.toplevel --dry-run` (amy locally; full builds via CI/deploy).
3. After deploy: `nix store ping --store ssh://nixremote@bam.d` as root on
   amy; trivial `nix build --rebuild` shows `building on 'ssh://…bam.d'`;
   bar icon click flips state within one poll interval (≤3 s) and
   `systemctl is-active remote-builders` agrees; toggled off, the same
   build runs locally.
