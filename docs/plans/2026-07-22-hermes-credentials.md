# Hermes Secrets via systemd Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flattened env-file secret pipeline with per-secret systemd credentials riding fw_cfg into the hermes microvm guests.

**Architecture:** Host `microvm@` drop-ins gain `LoadCredential=` per secret; the guest config maps each credential through `microvm.credentialFiles` (native qemu fw_cfg support); guest PID1 imports them as system credentials; the hermes-agent unit's existing preStart rewrites a marker-delimited block in `$HERMES_HOME/.env` from `$CREDENTIALS_DIRECTORY` (ssh CLI parity — upstream loads `.env` with `override=True`); the dashboard consumes its token via `ImportCredential` + inline export. Spec: `docs/2026-07-22-hermes-credentials-design.md`.

**Tech Stack:** NixOS module system, microvm.nix `credentialFiles` (qemu fw_cfg), systemd `LoadCredential`/`ImportCredential`, clan vars.

## Global Constraints

- Credential names ≤ 28 chars (qemu fw_cfg caps `opt/io.systemd.credentials/<NAME>` at 55) — enforced by assertion.
- `microvm.credentialFiles` values MUST be strings, never Nix path literals (a path literal copies the secret into the world-readable store).
- Secrets land in the guest state `.env` (0640, agent-owned) — required for ssh-launched `hermes` CLI sessions; unchanged property vs today.
- No formatters/linters/full test suites per task; verification is `nix build` of amy + targeted greps at the end of each task.

## Dependency Map

Tasks 1 and 2 both modify `modules/nixos/hermes-microvm.nix` — file contention forces serial execution. Task 3 consumes the `secretEnv` option interface from Task 1.

- Task 1: no dependencies
- Task 2: depends on 1 (same file; consumes credential names wiring)
- Task 3: depends on 1 (consumes `users.<u>.secretEnv`)

Waves (serial due to file contention): 1 → 2 → 3.

---

### Task 1: Transport — `secretEnv` option, host `LoadCredential`, guest `credentialFiles`

**Files:**
- Modify: `modules/nixos/hermes-microvm.nix` (provision script ~:103-122, sharePrepScript ~:180-195, guest `microvm` block ~:228-244 after `vsock.cid`, assertions ~:843, users submodule options ~:824-828, microvm@ drop-in ~:905, tmpfiles ~:965)

**Interfaces:**
- Consumes: nothing
- Produces: option `services.hermes-microvm.users.<u>.secretEnv :: attrsOf str` (env var name → host secret file path); per-user credential set = `attrNames secretEnv ++ [ "dashboard_token" ]`, each available in the guest at `/run/credentials/@system/<NAME>` (Task 2 consumes)

**Depends on:** none

- [ ] **Step 1: Replace the `environmentFiles` option with `secretEnv`** in the users submodule (currently:)

```nix
          environmentFiles = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Host paths of secret env files, assembled into the guest's hermes .env.";
          };
```

becomes:

```nix
          secretEnv = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = ''
              Env var name -> host file path (raw secret value, no KEY=
              prefix). Each entry rides a systemd credential into the guest
              (qemu fw_cfg) and is rewritten into $HERMES_HOME/.env before
              the agent starts. Names are limited to 28 chars (fw_cfg).
            '';
          };
```

- [ ] **Step 2: Add the name-length assertion.** The existing `assertions` is a `lib.mapAttrsToList` over duplicate uids; extend it:

```nix
    assertions = lib.mapAttrsToList (user: ucfg: {
      assertion = lib.count (u: u.uid == ucfg.uid) (lib.attrValues cfg.users) == 1;
      message = "services.hermes-microvm: duplicate uid ${toString ucfg.uid} (${user}) — uids derive ports, MAC and firewall identity and must be unique";
    }) cfg.users
    ++ lib.concatLists (lib.mapAttrsToList (user: ucfg:
      map (name: {
        assertion = builtins.stringLength name <= 28;
        message = "services.hermes-microvm.users.${user}.secretEnv.${name}: credential names must be <= 28 chars (qemu fw_cfg name limit)";
      }) (lib.attrNames ucfg.secretEnv)) cfg.users);
```

- [ ] **Step 3: Add a `credNames` helper to the `let` block** (near `vmName`/`vmUser`):

```nix
  # Credential set riding fw_cfg into a user's guest: the agent's secret
  # env vars plus the dashboard session token.
  credNames = ucfg: lib.attrNames ucfg.secretEnv ++ [ "dashboard_token" ];
```

- [ ] **Step 4: Host side — `LoadCredential` on the microvm@ drop-in.** In the `forEachUser` block that currently reads:

```nix
      "microvm@${vmName user}" = {
        # "+" = run with full privileges (the unit runs as the per-VM uid)
        serviceConfig.ExecStartPre = [ "+${provisionScript user ucfg}" ];
        # Override upstream's shared `microvm` user: one uid per VM keeps
        # guests distinguishable to netfilter and file permissions.
        serviceConfig.User = vmUser user;
      }
```

add:

```nix
        # Per-secret systemd credentials: qemu (the unit's main process)
        # reads them from $CREDENTIALS_DIRECTORY; the guest config maps
        # them through microvm.credentialFiles (fw_cfg). Strict: a missing
        # source file fails the VM start (fail-loud after a forgotten
        # `clan vars generate`).
        serviceConfig.LoadCredential =
          lib.mapAttrsToList (name: path: "${name}:${path}") ucfg.secretEnv
          ++ [ "dashboard_token:${baseDir user}/desktop-token" ];
```

- [ ] **Step 5: Guest side — `microvm.credentialFiles`.** In `guestConfig`'s `microvm = { … }` block (after `vsock.cid = ucfg.uid;`):

```nix
      # Secrets as fw_cfg credentials — never on a share, never on a
      # command line. STRING paths (a Nix path literal would copy the
      # secret into the store): the deterministic credentials dir of the
      # host unit that execs this qemu.
      credentialFiles = lib.genAttrs (credNames ucfg)
        (name: "/run/credentials/microvm@${vmName user}.service/${name}");
```

- [ ] **Step 6: Move desktop-token generation from `provisionScript` to `sharePrepScript`** (LoadCredential resolves when `microvm@` starts — before its ExecStartPre — so the token must exist by then; virtiofsd's ExecStartPre completes first). Delete from `provisionScript`:

```nix
    # dashboard session token; the 0400 owner-readable copy doubles as
    # HERMES_DESKTOP_REMOTE_TOKEN for the hermes-desktop wrapper.
    if [ ! -f "$base/desktop-token" ]; then
      (umask 277; openssl rand -hex 32 | tr -d '\n' > "$base/desktop-token")
    fi
    chown ${user} "$base/desktop-token"
    chmod 0400 "$base/desktop-token"
```

and append to `sharePrepScript` (add `openssl` to its `lib.makeBinPath` package list, `(with pkgs; [ coreutils openssl ])`):

```nix
    # dashboard session token: generated here (not in microvm@'s
    # ExecStartPre) because microvm@'s LoadCredential= resolves before
    # any ExecStartPre runs. 0400 owner copy doubles as
    # HERMES_DESKTOP_REMOTE_TOKEN for the hermes-desktop wrapper.
    if [ ! -f ${baseDir user}/desktop-token ]; then
      (umask 277; openssl rand -hex 32 | tr -d '\n' > ${baseDir user}/desktop-token)
    fi
    chown ${user} ${baseDir user}/desktop-token
    chmod 0400 ${baseDir user}/desktop-token
```

- [ ] **Step 7: Delete the secrets-file assembly from `provisionScript`** — the whole block:

```nix
    # secrets handed to the guest (root-only inside the ro mount)
    umask 077
    {
      printf 'HERMES_DASHBOARD_SESSION_TOKEN=%s\n' "$(cat "$base/desktop-token")"
    } > "$base/guest/secrets/dashboard.env"
    : > "$base/guest/secrets/hermes.env.tmp"
    ${lib.concatMapStrings (f: ''
      cat ${f} >> "$base/guest/secrets/hermes.env.tmp" 2>/dev/null \
        && printf '\n' >> "$base/guest/secrets/hermes.env.tmp" \
        || echo "hermes-microvm: missing environment file ${f}" >&2
    '') ucfg.environmentFiles}
    mv "$base/guest/secrets/hermes.env.tmp" "$base/guest/secrets/hermes.env"
```

Also update the provisionScript lead comment (`# Root ExecStartPre of microvm@hermes-<user>: …`) to drop "dashboard token, guest secret env files". Drop `openssl` from provisionScript's `makeBinPath` list (no remaining user).

- [ ] **Step 8: Drop the `guest/secrets` tmpfiles rule** — delete the line:

```nix
        "d ${baseDir user}/guest/secrets 0700 root root - -"
```

- [ ] **Step 9: Verify**

Run: `grep -n 'environmentFiles\|guest/secrets' modules/nixos/hermes-microvm.nix`
Expected: only the guest `services.hermes-agent.environmentFiles = [ "${guestHostDir}/secrets/hermes.env" ];` line remains (removed in Task 2); no `guest/secrets` writes in provisionScript, no tmpfiles rule.
(`nix build` deferred to Task 3 — `hermes-agent.nix` still sets `environmentFiles` until then, so eval fails mid-way by design at this point.)

---

### Task 2: Guest consumption — agent preStart rewrite, dashboard token import

**Files:**
- Modify: `modules/nixos/hermes-microvm.nix` (guest `services.hermes-agent` ~:373-402, guest `systemd.services.hermes-agent` ~:404-437, `systemd.services.hermes-dashboard` ~:443-479)

**Interfaces:**
- Consumes: per-user credential set from Task 1 (`credNames`, secrets at `$CREDENTIALS_DIRECTORY` of each importing unit)
- Produces: nothing downstream

**Depends on:** 1

- [ ] **Step 1: Stop feeding the upstream env-file path.** In guest `services.hermes-agent`, delete:

```nix
      environmentFiles = [ "${guestHostDir}/secrets/hermes.env" ];
```

(upstream default `[ ]`; non-secret `environment` keys keep flowing through upstream's activation seeding).

- [ ] **Step 2: Import credentials + rewrite `.env` in the agent unit.** In guest `systemd.services.hermes-agent`, add below `serviceConfig.ReadWritePaths`:

```nix
      # Secrets arrive as unit credentials ($CREDENTIALS_DIRECTORY is set
      # up before ExecStartPre and readable by the unit user).
      serviceConfig.ImportCredential = lib.attrNames ucfg.secretEnv;
```

and replace the existing `preStart` with (first stanza unchanged, second appended):

```nix
      preStart = ''
        env_file=${guestStateDir}/.hermes/.env
        touch "$env_file"
        ${pkgs.gnused}/bin/sed -i -E \
          '/^(export[[:space:]]+)?(PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|NIX_PYTHONPATH)=/d' \
          "$env_file"
        # Rewrite the credential-managed secret block: hermes loads .env
        # with override=True (beats process env) and ssh CLI sessions read
        # it directly, so credentials must land here. Strip-then-append
        # keeps rotated or removed keys from going stale.
        ${pkgs.gnused}/bin/sed -i \
          '/^# BEGIN hermes-microvm credentials$/,/^# END hermes-microvm credentials$/d' \
          "$env_file"
        if [ -n "''${CREDENTIALS_DIRECTORY:-}" ]; then
          {
            echo "# BEGIN hermes-microvm credentials"
            for f in "$CREDENTIALS_DIRECTORY"/*; do
              [ -f "$f" ] || continue
              printf '%s=%s\n' "$(basename "$f")" "$(cat "$f")"
            done
            echo "# END hermes-microvm credentials"
          } >> "$env_file"
        fi
      '';
```

(Note: single-line secret values only — same constraint as today's KEY=value concat. `touch` covers the empty-`environment` case where upstream's activation skips seeding.)

- [ ] **Step 3: Dashboard — credential instead of EnvironmentFile.** In `systemd.services.hermes-dashboard`:
  - change `after = [ "network-online.target" "hermes-python-venv.service" ];` to `after = [ "network-online.target" "hermes-python-venv.service" "hermes-agent.service" ];` and add the comment `# after hermes-agent: ordering only (not Requires) — its preStart refreshes the .env this process reads at startup.`
  - drop `guestHostDir` from its `unitConfig.RequiresMountsFor` list (no longer reads the share): `unitConfig.RequiresMountsFor = [ guestStateDir (exchangeDir user) ];`
  - in `serviceConfig`, delete `EnvironmentFile = "${guestHostDir}/secrets/dashboard.env";`, add `ImportCredential = "dashboard_token";`, and replace `ExecStart` with:

```nix
        # Token as env var: read from the unit's credentials dir at start.
        ExecStart = pkgs.writeShellScript "hermes-dashboard-start" ''
          HERMES_DASHBOARD_SESSION_TOKEN=$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/dashboard_token")
          export HERMES_DASHBOARD_SESSION_TOKEN
          exec ${config.services.hermes-agent.package}/bin/hermes dashboard \
            --no-open --host 127.0.0.1 --port ${toString dashboardGuestBackendPort}
        '';
```

- [ ] **Step 4: Update the module header** (lines ~1-33): in the host<->guest interfaces section, add `#   - secrets: per-secret systemd credentials (LoadCredential -> qemu fw_cfg -> guest PID1); the ro host-config share carries only ssh keys + tz.`

- [ ] **Step 5: Verify**

Run: `grep -n 'dashboard.env\|guest/secrets\|environmentFiles' modules/nixos/hermes-microvm.nix`
Expected: no matches.

---

### Task 3: Consumer — per-secret clan vars in `hermes-agent.nix`

**Files:**
- Modify: `modules/nixos/hermes-agent.nix` (generator ~:40-57, `users.grmpf` ~:84-88, header comment ~:6-8)

**Interfaces:**
- Consumes: `services.hermes-microvm.users.<u>.secretEnv` (Task 1)
- Produces: nothing

**Depends on:** 1

- [ ] **Step 1: Replace the `hermes-env` generator with a `telegram` generator.** Delete the whole `clan.core.vars.generators.hermes-env = { … };` block and add (persist prompts auto-materialize as `files.<name>` — same pattern as `openrouter`, cf. `pi-chat-openrouter.nix:9-24`):

```nix
  # Telegram platform secrets, one file per value. Restarting the VM
  # re-resolves LoadCredential= from the freshly decrypted vars.
  clan.core.vars.generators.telegram = {
    prompts.token.type = "hidden";
    prompts.token.persist = true;
    prompts.allowed_users.type = "hidden";
    prompts.allowed_users.persist = true;
    files.token.restartUnits = [ "microvm@hermes-grmpf.service" ];
    files.allowed_users.restartUnits = [ "microvm@hermes-grmpf.service" ];
  };
```

Also add to the shared `openrouter` generator declaration in this file:

```nix
    files.apikey.restartUnits = [ "microvm@hermes-grmpf.service" ];
```

(restartUnits merge across declarations; rotation restarts the VM.)

- [ ] **Step 2: Wire `secretEnv`.** Replace in `users.grmpf`:

```nix
      environmentFiles = [ config.clan.core.vars.generators.hermes-env.files.env.path ];
```

with:

```nix
      secretEnv = {
        OPENROUTER_API_KEY = config.clan.core.vars.generators.openrouter.files.apikey.path;
        TELEGRAM_BOT_TOKEN = config.clan.core.vars.generators.telegram.files.token.path;
        TELEGRAM_ALLOWED_USERS = config.clan.core.vars.generators.telegram.files.allowed_users.path;
      };
```

- [ ] **Step 3: Update the file header comment** (lines 6-8) to describe the credential path instead of "renders the KEY=value env file handed into the guest".

- [ ] **Step 4: Verify**

Run: `grep -rn 'hermes-env' modules/ machines/`
Expected: no matches.
Run: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link`
Expected: success.

- [ ] **Step 5: Stale var note.** `vars/per-machine/amy/hermes-env/` becomes orphaned; remove it in the same change (`git rm -r vars/per-machine/amy/hermes-env` equivalent via jj) — the new `telegram` var is produced by the operator running `clan vars generate` before deploy (interactive; NOT part of this plan's execution).

---

## Deploy-time runbook (operator, after merge)

1. `clan vars generate` (prompts for telegram token + allowed users).
2. Deploy amy; then in the guest: `systemd-creds list` shows `OPENROUTER_API_KEY TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS dashboard_token`; the marker block exists in `/var/lib/hermes/.hermes/.env`.
3. `hermes` over ssh → telegram platform up (gateway log / `hermes doctor`).
4. `hermes-desktop` connects with the token.
5. Negative test: move a var file away, `systemctl restart microvm@hermes-grmpf` → clean credential failure.
