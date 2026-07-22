# Hermes secrets via systemd credentials

Date: 2026-07-22. Status: implemented.
Scope: `modules/nixos/hermes/` (formerly `hermes-microvm.nix`/`hermes-agent.nix`).

## Problem

Secrets reach the guest through a single flattened env file: the `hermes-env`
clan vars generator exists only to mash unrelated secrets (openrouter key +
telegram token + telegram allowlist) into one `KEY=value` blob, which the
root provision script concatenates into `guest/secrets/hermes.env` on the ro
virtiofs share, and upstream's activation script merges into
`$HERMES_HOME/.env`. Adding a secret means editing the combining generator.
The dashboard token travels a parallel bespoke path (`dashboard.env` +
`EnvironmentFile=`).

## Design

Per-secret systemd credentials, end to end, using only native mechanisms:

```
per-secret clan vars (openrouter/apikey, telegram/token, telegram/allowed_users)
  → host drop-in: systemd.services."microvm@hermes-<user>".serviceConfig
      .LoadCredential = [ "<NAME>:<var path>" ]
  → guest cfg: microvm.credentialFiles.<NAME> =
      "/run/credentials/microvm@hermes-<user>.service/<NAME>"   (string!)
  → qemu -fw_cfg name=opt/io.systemd.credentials/<NAME>,file=…
  → guest PID1 imports to /run/credentials/@system/<NAME> (0400 root)
  → consuming guest unit: ImportCredential=<NAME> → $CREDENTIALS_DIRECTORY
```

Verified facts the design rests on (see agent://MicrovmCredSupport,
agent://HermesEnvConsumption for cited sources):

- microvm.nix (pinned rev a8ddffe) ships `microvm.credentialFiles`,
  qemu-only, with an upstream CI check; each entry becomes a `-fw_cfg`
  argument. Secrets never appear on a command line.
- The host `microvm@` unit `exec`s qemu as its main process, so a
  `LoadCredential=` drop-in exposes the deterministic
  `/run/credentials/microvm@<vm>.service/<NAME>` path to qemu. That path is
  passed to `credentialFiles` as a **string** — a Nix path literal would
  copy the secret into the world-readable store.
- `$CREDENTIALS_DIRECTORY` is set up before `ExecStartPre` and is readable
  by the unit's `User=` — preStart scripts can consume credentials without
  root.
- Upstream hermes loads `$HERMES_HOME/.env` with `override=True` (file
  beats process env), and every ssh-launched CLI entry point reads it
  itself. Secrets therefore MUST land in the state-dir `.env`; pure
  unit-env injection cannot serve interactive sessions.

### Module interface

`services.hermes-microvm.users.<u>.environmentFiles` (list, concatenated) is
replaced by:

```nix
users.<u>.secretEnv = {
  # env var name → host secret file path (raw value, no KEY= prefix)
  OPENROUTER_API_KEY     = <clan vars openrouter/apikey path>;
  TELEGRAM_BOT_TOKEN     = <clan vars telegram/token path>;
  TELEGRAM_ALLOWED_USERS = <clan vars telegram/allowed_users path>;
};
```

Assertion: credential names ≤ 28 chars (fw_cfg caps the full
`opt/io.systemd.credentials/<NAME>` at 55).

### Host side

- Drop-in on `microvm@hermes-<user>`: one `LoadCredential=<NAME>:<path>`
  per `secretEnv` entry, plus `dashboard_token:<base>/desktop-token`.
- Desktop-token generation moves from `microvm@`'s provision ExecStartPre
  into `sharePrepScript` (virtiofsd's ExecStartPre, which completes before
  `microvm@` starts) — otherwise first-boot `LoadCredential` would race the
  file's creation.
- Deleted: the env-concat block in the provision script, the
  `guest/secrets/*` writes, `dashboard.env`, and the `guest/secrets`
  tmpfiles rule. The ro host-config share carries only ssh keys + tz.

### Guest side (zero new units)

- `hermes-agent` unit: `ImportCredential=` for every `secretEnv` name; the
  existing preStart (which already strips `PYTHONPATH` & friends) also
  rewrites a marker-delimited block in `${stateDir}/.hermes/.env` from
  `$CREDENTIALS_DIRECTORY` — strip block, append fresh, so rotated or
  removed keys cannot go stale. Runs as the unit user (`.env` is 0640,
  agent-owned). Upstream's activation seeding keeps handling the non-secret
  `cfg.environment` keys; `environmentFiles = [ ]` upstream.
- `hermes-dashboard` unit: `ImportCredential=dashboard_token`, exports
  `HERMES_DASHBOARD_SESSION_TOKEN` from `$CREDENTIALS_DIRECTORY` in an
  inline ExecStart wrapper (replaces `EnvironmentFile=`), and gains
  `After=hermes-agent.service` (ordering only) so it starts after the
  `.env` rewrite.
- ssh CLI sessions read the `.env` refreshed at boot by the agent preStart
  — same semantics as today's activation-seeded file.

### clan vars

- `hermes-env` generator deleted.
- New `telegram` generator: prompts `token` and `allowed_users`, each its
  own raw value file, secret, `restartUnits = [ "microvm@hermes-grmpf.service" ]`.
- `openrouter` var consumed directly — no re-rendering.

## Accepted tradeoffs

- Secrets still persist in the guest `.env` on the root-hidden vault:
  required for ssh CLI parity (`override=True`), unchanged vs today.
- A missing secret file now fails the VM start (`LoadCredential` is
  strict) instead of warn-and-continue — fail-loud after a forgotten
  `clan vars generate`.
- If the agent unit fails at boot, the dashboard reads the previous boot's
  `.env` — same staleness class as a failed activation today.

## Verification

1. `nix build .#nixosConfigurations.amy.config.system.build.toplevel`.
2. Deploy; in the guest: `systemd-creds list` shows the imported names;
   `grep` the marker block in `/var/lib/hermes/.hermes/.env`.
3. `hermes` over ssh sees the secrets (e.g. telegram platform up in
   `hermes doctor` / gateway log).
4. Dashboard reachable with the token from `hermes-desktop`.
5. Negative: remove one credential source file, `systemctl restart
   microvm@hermes-grmpf` → unit fails with a credential error, not a
   half-configured agent.
