# Remote Building Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A generic `remote-building` clan service (builder/client roles, all auth via clan vars), instantiated as amy→bam, with a noctalia bar icon toggling remote builds at runtime, covered by a clan container test.

**Architecture:** The client role generates an ssh keypair + nix signing keypair via clan vars, renders builders through NixOS's `nix.buildMachines` (→ `/etc/nix/machines`), and points `nix.settings.builders` at `/run/remote-builders/machines`; a oneshot `remote-builders.service` copies/truncates that file (toggle), polkit lets wheel flip it. The builder role runs an unprivileged `nixremote` user whose `authorized_keys` and `nix.settings.trusted-public-keys` are read from each client's in-repo public vars — no `trusted-users`. The bar icon is a noctalia built-in CustomButton seeded by an append-only settings.json merge.

**Tech Stack:** clan services (`_class = "clan.service"`), clan vars generators, `clanLib.getPublicValue`, clan-core `flakeModules.testModule` container tests, noctalia CustomButton, jq, polkit.

**Spec:** `docs/superpowers/specs/2026-07-22-remote-building-design.md`

## Global Constraints

- All authentication material via clan vars generators; no manual key handling, no committed secrets.
- Builder NEVER adds clients to `nix.settings.trusted-users`.
- Toggle default: ON at boot (`wantedBy multi-user.target`).
- No global ssh `Host` blocks for the builder (would change interactive `ssh <builder>.d` for every user) — spec §1 correction: ssh user + identity travel in the machines-file fields (`sshUser`, `sshKey`).
- Follow house clan-service style (`modules/clan/nix-cache/default.nix`); noctalia merge follows `modules/nixos/noctalia-anthropic-usage/merge.sh` (append-only, idempotent, user layout preserved).
- Vars generator name is `remote-building-<instanceName>`; files: `ssh.id` (secret), `ssh.id.pub`, `signing.key` (secret), `signing.key.pub`.
- Toggle unit name is exactly `remote-builders.service`; state file `/run/remote-builders/machines`.
- Verify with targeted eval/checks only — no repo-wide formatters or unrelated test suites.

## Dependency Map

- Task 1: no dependencies (service module + registration + inventory instance)
- Task 2: depends on 1 (clan test consumes the module + instance shape)
- Task 3: depends on 1 (widget consumes `remote-builders.service` + polkit rule + `barToggle` import hook)
- Task 4: depends on 1, 2, 3 (vars generation, full verification, spec sync)

Waves:
1. Task 1
2. Tasks 2, 3 (parallel)
3. Task 4

---

### Task 1: `remote-building` clan service + registration + instance

**Files:**
- Create: `modules/clan/remote-building/default.nix`
- Modify: `modules/flake-parts/nixosConfigurations.nix` (~line 43: `modules` attrset; ~line 152: after the `sshd` instance)
- Modify: `modules/nixos/laptop-dave.nix:108-115` (delete dead commented `nix.buildMachines` block)

**Interfaces:**
- Consumes: `clanLib.getPublicValue { flake, machine, generator, file, default }` (clan-core); `roles.<role>.machines.<name>.settings` (clan service API); existing `nix-caches.nix` already defines `nix.settings.trusted-public-keys` on bam (list defs merge).
- Produces:
  - Clan module `remote-building` with `roles.builder` (settings: `host : nullOr str = null`, `maxJobs : int = 10`, `speedFactor : int = 2`, `systems : listOf str = ["x86_64-linux" "aarch64-linux"]`, `supportedFeatures : listOf str = ["nixos-test" "big-parallel" "kvm" "benchmark"]`) and `roles.client` (settings: `barToggle : bool = false`).
  - On clients: systemd unit `remote-builders.service`, file `/run/remote-builders/machines`, polkit rule for wheel on that unit, vars generator `remote-building-<instanceName>`.
  - On builders: user `nixremote`, client keys in `authorized_keys` + `trusted-public-keys`.
  - `barToggle = true` imports `../../nixos/noctalia-remote-build` (created in Task 3; guarded so eval without the dir fails loudly — Task 3 creates it before Task 4 evals amy).
- **Depends on:** none

- [ ] **Step 1: Register module + instance first (the failing "test")**

In `modules/flake-parts/nixosConfigurations.nix` add to the `modules` attrset (after `cctl`, line ~43):

```nix
          remote-building = ../../modules/clan/remote-building;
```

and after the `sshd` instance (line ~152) add:

```nix
            remote-building = {
              module.name = "remote-building";
              module.input = "self";
              roles.builder.machines.bam = {};
              # barToggle stays false until Task 3 lands the widget module;
              # Task 4 flips it to true.
              roles.client.machines.amy = {};
            };
```

- [ ] **Step 2: Verify it fails (module path missing)**

Run: `nix eval .#nixosConfigurations.amy.config.system.build.toplevel.drvPath 2>&1 | tail -5`
Expected: FAIL — path `modules/clan/remote-building` does not exist.

- [ ] **Step 3: Write the service module**

Create `modules/clan/remote-building/default.nix`:

```nix
# Distributed nix builds between clan machines.
#
# roles.builder: accepts builds as the unprivileged `nixremote` user.
#   Clients are authenticated by ssh key and their store paths by nix
#   signing key — both read from the clients' in-repo public vars.
#   Deliberately NO nix.settings.trusted-users: an untrusted caller can
#   only import paths signed by a key in trusted-public-keys.
# roles.client: generates ssh + signing keypairs (clan vars), signs every
#   locally-registered path (secret-key-files), and exposes the builders
#   through a runtime-switchable machines file:
#     nix.buildMachines -> /etc/nix/machines (NixOS-rendered)
#     builders = @/run/remote-builders/machines
#     remote-builders.service copies (start) / truncates (stop) it.
#   Members of wheel may flip the unit without a password (polkit).
{ clanLib, ... }:
{
  _class = "clan.service";
  manifest.name = "hyperconfig/remote-building";
  manifest.description = "Offload nix builds to builder machines over ssh; keys and signatures via clan vars";
  manifest.categories = [ "System" ];

  roles.builder = {
    description = "Accepts builds from the client machines as the unprivileged nixremote user.";

    interface =
      { lib, ... }:
      {
        options = {
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Hostname clients connect to. Default: <machineName>.d (clan domain).";
          };
          maxJobs = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Max parallel builds a client schedules here.";
          };
          speedFactor = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = "Relative speed vs the client (higher = preferred).";
          };
          systems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "x86_64-linux" "aarch64-linux" ];
            description = "Systems this builder accepts.";
          };
          supportedFeatures = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "nixos-test" "big-parallel" "kvm" "benchmark" ];
            description = "Features advertised to clients.";
          };
        };
      };

    perInstance =
      { instanceName, roles, ... }:
      {
        nixosModule =
          { config, lib, ... }:
          let
            # Public var of one client machine; null until its vars are
            # generated so the builder still evaluates on a fresh checkout.
            clientVals =
              file:
              lib.filter (v: v != null) (
                map (
                  machine:
                  clanLib.getPublicValue {
                    flake = config.clan.core.settings.directory;
                    generator = "remote-building-${instanceName}";
                    inherit machine file;
                    default = null;
                  }
                ) (lib.attrNames (roles.client.machines or { }))
              );
          in
          {
            services.openssh.enable = true;

            users.groups.nixremote = { };
            users.users.nixremote = {
              isNormalUser = true;
              group = "nixremote";
              # The ssh store protocol runs `nix-store --serve` through the
              # login shell; nologin would break it.
              useDefaultShell = true;
              openssh.authorizedKeys.keys = map lib.trim (clientVals "ssh.id.pub");
            };

            # Accept client-signed store paths. NOT trusted-users: this is
            # the whole point — an untrusted user may only import paths
            # carrying a signature the daemon already trusts.
            nix.settings.trusted-public-keys = map lib.trim (clientVals "signing.key.pub");
          };
      };
  };

  roles.client = {
    description = "Offloads builds to the builder machines; bar toggle optional.";

    interface =
      { lib, ... }:
      {
        options.barToggle = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Seed the noctalia CustomButton that toggles remote-builders.service.";
        };
      };

    perInstance =
      {
        instanceName,
        roles,
        settings,
        ...
      }:
      {
        nixosModule =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            gen = config.clan.core.vars.generators."remote-building-${instanceName}";
            machineName = config.clan.core.settings.machine.name;
          in
          {
            imports = lib.optional settings.barToggle ../../nixos/noctalia-remote-build;

            clan.core.vars.generators."remote-building-${instanceName}" = {
              files."ssh.id" = { };            # secret, deployed (defaults)
              files."ssh.id.pub".secret = false;
              files."signing.key" = { };       # secret, deployed
              files."signing.key.pub".secret = false;
              runtimeInputs = [
                pkgs.openssh
                pkgs.nix
              ];
              script = ''
                ssh-keygen -t ed25519 -N "" \
                  -C "${machineName}-remote-building-${instanceName}" \
                  -f "$out"/ssh.id
                nix key generate-secret \
                  --key-name "${machineName}-remote-building-${instanceName}-1" \
                  > "$out"/signing.key
                nix key convert-secret-to-public \
                  < "$out"/signing.key > "$out"/signing.key.pub
              '';
            };

            # Sign every path this machine registers, so builders accept
            # them without trusting the connection itself.
            nix.settings.secret-key-files = [ gen.files."signing.key".path ];

            nix.distributedBuilds = true;
            nix.settings.builders-use-substitutes = true;

            # NixOS renders these into /etc/nix/machines; the toggle unit
            # decides whether the daemon sees them (builders = @/run/...).
            nix.buildMachines = lib.mapAttrsToList (name: machine: {
              hostName = if machine.settings.host != null then machine.settings.host else "${name}.d";
              protocol = "ssh";
              sshUser = "nixremote";
              sshKey = gen.files."ssh.id".path;
              inherit (machine.settings)
                systems
                maxJobs
                speedFactor
                supportedFeatures
                ;
            }) (roles.builder.machines or { });

            # nix tolerates an empty @file but the unit must never race a
            # missing one at boot.
            systemd.tmpfiles.rules = [
              "d /run/remote-builders 0755 root root -"
              "f /run/remote-builders/machines 0444 root root -"
            ];
            nix.settings.builders = "@/run/remote-builders/machines";

            systemd.services.remote-builders = {
              description = "Expose remote nix builders to the daemon (stop = build locally)";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/install -m 0444 /etc/nix/machines /run/remote-builders/machines";
                ExecStop = "${pkgs.coreutils}/bin/install -m 0444 /dev/null /run/remote-builders/machines";
              };
            };

            security.polkit.extraConfig = ''
              polkit.addRule(function(action, subject) {
                if (action.id == "org.freedesktop.systemd1.manage-units" &&
                    action.lookup("unit") == "remote-builders.service" &&
                    subject.isInGroup("wheel")) {
                  return polkit.Result.YES;
                }
              });
            '';
          };
      };
  };
}
```

- [ ] **Step 4: Delete the dead block**

In `modules/nixos/laptop-dave.nix` remove lines 108–115 (the commented `nix.buildMachines = [ { hostName = "bam.d"; ... } ];` block). Keep line 107 (`nix.settings.max-jobs = 40;`).

- [ ] **Step 5: Verify both machines evaluate**

Run: `nix eval .#nixosConfigurations.amy.config.system.build.toplevel.drvPath`
Expected: PASS (a `/nix/store/....drv` path). Client vars are referenced only by deterministic path, so eval works before `clan vars generate`.

Run: `nix eval .#nixosConfigurations.bam.config.system.build.toplevel.drvPath`
Expected: PASS — `getPublicValue` returns the `default = null` fallback (amy's vars not generated yet), so `nixremote` has zero keys but bam evaluates.

Run: `nix eval .#nixosConfigurations.amy.config.systemd.services.remote-builders.wantedBy`
Expected: `[ "multi-user.target" ]`

---

### Task 2: Clan container test

**Files:**
- Create: `modules/clan/remote-building/tests/vm/default.nix`
- Create: `modules/flake-parts/clan-tests.nix`

**Interfaces:**
- Consumes: Task 1's module (roles/settings incl. `roles.builder...settings.host`); `inputs.clan-core.flakeModules.testModule` (provides `perSystem` option `clan.nixosTests.<name>`, auto-exposed as `checks.<system>.<name>`); test harness auto-generates vars at eval time (NO committed `vars/`/`sops/`, NO `update-vars`).
- Produces: `checks.x86_64-linux.remote-building`.
- **Depends on:** 1

- [ ] **Step 1: Write the flake-parts wiring**

Create `modules/flake-parts/clan-tests.nix` (auto-imported by `all-modules.nix`):

```nix
# Clan service tests, exposed as checks.<system>.<name> via clan-core's
# test harness (container tests; vars are generated at eval time).
{ inputs, ... }:
{
  imports = [ inputs.clan-core.flakeModules.testModule ];

  perSystem = _: {
    clan.nixosTests.remote-building = {
      imports = [ ../clan/remote-building/tests/vm/default.nix ];
      clan.modules.remote-building = ../clan/remote-building;
    };
  };
}
```

- [ ] **Step 2: Write the test**

Create `modules/clan/remote-building/tests/vm/default.nix`:

```nix
# Contract of the remote-building service, e2e:
#   1. toggle ON at boot: machines file lists the builder
#   2. stop/start round-trip empties/restores it
#   3. root@client authenticates as nixremote@builder with the deployed var key
#   4. a dependent build offloads: client-BUILT (signed) input is accepted
#      by the builder WITHOUT trusted-users, output is copied back
#   5. nixremote is not a trusted user on the builder (config assertion;
#      an unsigned-push probe is impossible from the client because
#      secret-key-files signs every local registration)
#
# Host keys: prod trusts them via the clan-core sshd CA; that service is
# out of scope here, so the test seeds known_hosts with ssh-keyscan.
{ ... }:
{
  name = "remote-building";

  clan = {
    directory = ./.;
    test.useContainers = true;
    inventory = {
      machines.builder1 = { };
      machines.client1 = { };

      instances = {
        remote-building = {
          module.name = "remote-building";
          module.input = "self";
          # Test network resolves bare hostnames, not <name>.d
          roles.builder.machines.builder1.settings.host = "builder1";
          roles.client.machines.client1 = { };
        };
      };
    };
  };

  nodes = {
    builder1 = {
      # Nested builds inside the test node cannot sandbox.
      nix.settings.sandbox = false;
      nix.settings.experimental-features = [ "nix-command" ];
    };
    client1 = {
      nix.settings.sandbox = false;
      nix.settings.experimental-features = [ "nix-command" ];
    };
  };

  testScript = ''
    start_all()

    builder1.wait_for_unit("sshd.service")
    client1.wait_for_unit("multi-user.target")

    # 1. ON at boot
    client1.wait_for_unit("remote-builders.service")
    machines = client1.succeed("cat /run/remote-builders/machines")
    assert "ssh://nixremote@builder1" in machines, machines

    # 2. toggle round-trip
    client1.succeed("systemctl stop remote-builders.service")
    assert client1.succeed("cat /run/remote-builders/machines").strip() == ""
    client1.succeed("systemctl start remote-builders.service")
    assert "ssh://nixremote@builder1" in client1.succeed("cat /run/remote-builders/machines")

    # host keys: prod uses the sshd CA; the test seeds known_hosts instead
    client1.succeed("mkdir -p /root/.ssh && ssh-keyscan builder1 >> /root/.ssh/known_hosts")

    # 3. ssh auth purely from deployed vars
    ssh_key = client1.succeed("awk '{print $3}' /etc/nix/machines").strip()
    client1.succeed(f"ssh -o BatchMode=yes -i {ssh_key} nixremote@builder1 true")

    # 4. e2e: dep built LOCALLY first (signed on registration by
    # secret-key-files), then top forced remote — the builder must accept
    # the client-signed dep path without trusted-users, build top, and the
    # daemon copies the output back.
    dep_expr = """derivation {
        name = "remote-building-dep";
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [ "-c" "echo dep > $out" ];
      }"""
    top_expr = f"""let dep = {dep_expr}; in derivation {{
        name = "remote-building-top";
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [ "-c" "cat $dep > $out; echo top >> $out" ];
        inherit dep;
      }}"""
    # dep: local only (empty --builders overrides the machines file)
    client1.succeed(f"nix build --builders '' --expr '{dep_expr}' --out-link /tmp/dep")
    dep_path = client1.succeed("readlink -f /tmp/dep").strip()
    # proof the signing chain is live before involving the builder
    sigs = client1.succeed(f"nix path-info --sigs {dep_path}")
    assert "client1-remote-building-remote-building-1:" in sigs, sigs
    # top: remote only
    client1.succeed(f"nix build -L --max-jobs 0 --expr '{top_expr}' --out-link /tmp/result 2>&1")
    top_path = client1.succeed("readlink -f /tmp/result").strip()
    # output present on BOTH: built remotely, copied back
    builder1.succeed(f"test -e {top_path}")
    assert client1.succeed(f"cat {top_path}").strip().endswith("top")

    # 5. untrusted: no trusted-users grant anywhere for nixremote
    builder1.fail("grep -R nixremote /etc/nix/nix.conf | grep trusted-users")
  '';
}
```

Note: the two-invocation split (dep with `--builders ''`, top with
`--max-jobs 0`) is deliberate — a single expression under `--max-jobs 0`
would push the dep build remote as well and never exercise the signed
upload of a client-built input.

- [ ] **Step 3: Run the check**

Run: `nix build .#checks.x86_64-linux.remote-building -L`
Expected: PASS. Known fallbacks, in order:
1. Container/nspawn fights the nested nix daemon → set `clan.test.useContainers = false;` in the test (spec-sanctioned fallback) and re-run.
2. `uid-range` missing on the build host (containers only) → same fallback.
3. Signature rejection on the dep path (would show `cannot add path ... lacks a valid signature` in the builder log) → this is assertion-4 failing honestly; do NOT paper over with `require-sigs = false`. Debug the signing chain (`nix path-info --sigs <dep>` on client must show `client1-remote-building-remote-building-1:...`).

- [ ] **Step 4: Confirm the check is discoverable**

Run: `nix flake show 2>/dev/null | grep -A1 remote-building`
Expected: `checks.x86_64-linux.remote-building` listed.

---

### Task 3: Noctalia bar toggle

**Files:**
- Create: `modules/nixos/noctalia-remote-build/default.nix`
- Create: `modules/nixos/noctalia-remote-build/merge.sh`

**Interfaces:**
- Consumes: `remote-builders.service` + wheel polkit rule (Task 1); noctalia CustomButton widget settings keys (verified against noctalia-shell 4.7.7 `Modules/Bar/Widgets/CustomButton.qml`): `id`, `icon`, `leftClickExec`, `leftClickUpdateText`, `textCommand`, `textIntervalMs`, `parseJson`; status JSON keys `icon`, `tooltip`, `iconColor` (valid: primary/secondary/tertiary/error/none). Exec runs via `sh -lc`; use the stable profile path `/run/current-system/sw/bin/…`, never a store path (stale after GC).
- Produces: nixos module at `modules/nixos/noctalia-remote-build` imported by Task 1's `barToggle = true`; `remote-build-toggle` CLI (`status`|`toggle`) in systemPackages.
- **Depends on:** 1

- [ ] **Step 1: Write the module**

Create `modules/nixos/noctalia-remote-build/default.nix`:

```nix
# Noctalia bar icon toggling remote-builders.service (remote nix builds).
#
# No QML: noctalia's built-in CustomButton widget polls
# `remote-build-toggle status` (JSON: icon/tooltip/iconColor) and runs
# `remote-build-toggle toggle` on click; leftClickUpdateText refreshes the
# icon immediately after the click. Toggling needs no password: the
# remote-building client role ships a polkit rule for wheel on exactly
# this unit.
#
# merge.sh seeds the widget into ~/.config/noctalia/settings.json as an
# extra noctalia-shell ExecStartPre AFTER the spaces bundle's
# noctalia-config-merge — append-only and idempotent, the user's own
# layout survives (same contract as noctalia-anthropic-usage).
{ lib, pkgs, ... }:
let
  toggle = pkgs.writeShellApplication {
    name = "remote-build-toggle";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      unit=remote-builders.service
      case "''${1:-}" in
        status)
          if systemctl is-active --quiet "$unit"; then
            printf '{"icon":"cloud_upload","iconColor":"primary","tooltip":"Remote builds: ON — click to build locally"}\n'
          else
            printf '{"icon":"cloud_off","tooltip":"Remote builds: OFF — click to offload"}\n'
          fi
          ;;
        toggle)
          if systemctl is-active --quiet "$unit"; then
            systemctl stop "$unit"
          else
            systemctl start "$unit"
          fi
          ;;
        *)
          echo "usage: remote-build-toggle {status|toggle}" >&2
          exit 2
          ;;
      esac
    '';
  };

  mergeConfig = pkgs.writeShellApplication {
    name = "noctalia-remote-build-merge";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./merge.sh;
  };
in
{
  environment.systemPackages = [ toggle ];

  systemd.user.services.noctalia-shell = {
    # After the spaces bundle's noctalia-config-merge (mkAfter), so the
    # managed settings.json is already seeded.
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${mergeConfig}/bin/noctalia-remote-build-merge"
    ];
    restartTriggers = [ mergeConfig ];
  };
}
```

- [ ] **Step 2: Write the merge script**

Create `modules/nixos/noctalia-remote-build/merge.sh`:

```bash
# Seed the remote-build CustomButton into noctalia's settings.json.
#
# Append-only: if any CustomButton in the bar already runs
# remote-build-toggle (any section, any screen override), do nothing —
# the user may have moved or restyled it. Missing/corrupt settings.json
# starts from {}.
set -euo pipefail

cfgDir="${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"
target="$cfgDir/settings.json"
mkdir -p "$cfgDir"

widget='{
  "id": "CustomButton",
  "icon": "cloud_upload",
  "leftClickExec": "/run/current-system/sw/bin/remote-build-toggle toggle",
  "leftClickUpdateText": true,
  "textCommand": "/run/current-system/sw/bin/remote-build-toggle status",
  "textIntervalMs": 5000,
  "parseJson": true
}'

if ! existing="$(jq -e . "$target" 2>/dev/null)"; then
  existing='{}'
fi

tmp="$(mktemp "$cfgDir/.remote-build-merge.XXXXXX")"
printf '%s' "$existing" | jq --argjson w "$widget" '
  if ([.. | objects | select(.id? == "CustomButton")
         | .textCommand // "" | select(test("remote-build-toggle"))]
      | length) > 0
  then .
  else .bar.widgets.right = ((.bar.widgets.right // []) + [$w])
  end
' > "$tmp"
mv "$tmp" "$target"
```

- [ ] **Step 3: Test the merge (fresh, idempotent, user-widget preserved)**

Run:

```bash
tmp=$(mktemp -d) && HOME=$tmp XDG_CONFIG_HOME= bash -c '
  set -e
  merge() { bash modules/nixos/noctalia-remote-build/merge.sh; }
  # fresh host (jq + coreutils assumed on PATH — direnv devshell has them)
  merge
  jq -e ".bar.widgets.right | length == 1" ~/.config/noctalia/settings.json
  # idempotent
  merge
  jq -e ".bar.widgets.right | length == 1" ~/.config/noctalia/settings.json
  # user layout preserved + user-moved widget respected
  jq ".bar.widgets.left = [{\"id\":\"Clock\"}]" ~/.config/noctalia/settings.json > s && mv s ~/.config/noctalia/settings.json
  merge
  jq -e ".bar.widgets.left == [{\"id\":\"Clock\"}] and (.bar.widgets.right | length == 1)" ~/.config/noctalia/settings.json
  echo MERGE-OK
' && rm -rf $tmp
```

Expected: `MERGE-OK`. (If `nixpkgs#jq` is awkward in the sandbox, `jq` from the dev environment is fine — the script only needs jq + coreutils.)

- [ ] **Step 4: Eval the module standalone**

Run: `nix eval --impure --expr 'let pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux; m = import ./modules/nixos/noctalia-remote-build { lib = pkgs.lib; inherit pkgs; }; in builtins.attrNames m'`
Expected: `[ "environment" "systemd" ]`

---

### Task 4: Wire amy's toggle, generate vars, full verification, spec sync

**Files:**
- Modify: `modules/flake-parts/nixosConfigurations.nix` (the `remote-building` instance from Task 1)
- Modify: `docs/superpowers/specs/2026-07-22-remote-building-design.md` (two amendments)
- Create (generated): `vars/per-machine/amy/remote-building-remote-building/**` via `clan vars generate`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: deployable amy/bam configs; green `checks.x86_64-linux.remote-building`.
- **Depends on:** 1, 2, 3

- [ ] **Step 1: Enable amy's bar toggle**

In the `remote-building` instance, change the client line to:

```nix
              roles.client.machines.amy.settings.barToggle = true;
```

and drop the interim comment from Task 1 Step 1.

- [ ] **Step 2: Generate amy's vars**

Run: `clan vars generate amy`
Expected: creates `vars/per-machine/amy/remote-building-remote-building/{ssh.id,ssh.id.pub,signing.key,signing.key.pub}` — pubkeys as plaintext `value` files, secrets sops-encrypted. Inspect: `cat vars/per-machine/amy/remote-building-remote-building/ssh.id.pub/value` → single `ssh-ed25519 ...` line; `.../signing.key.pub/value` → `amy-remote-building-remote-building-1:<base64>`.

- [ ] **Step 3: Full eval + builder picks up the keys**

Run: `nix eval .#nixosConfigurations.bam.config.users.users.nixremote.openssh.authorizedKeys.keys`
Expected: list with amy's ed25519 pubkey (no longer empty).

Run: `nix eval .#nixosConfigurations.bam.config.nix.settings.trusted-public-keys`
Expected: contains `amy-remote-building-remote-building-1:...` plus the existing nix-caches keys.

Run: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --dry-run` and same for `bam`
Expected: PASS (dry-run realisability; full build happens at deploy).

- [ ] **Step 4: Re-run the clan test**

Run: `nix build .#checks.x86_64-linux.remote-building -L`
Expected: PASS (unchanged by the amy/bam wiring, guards regressions from Task 4 edits).

- [ ] **Step 5: Spec amendments**

In `docs/superpowers/specs/2026-07-22-remote-building-design.md`:
1. §1 client role: replace the root-ssh-config bullet with the machines-file mechanism (`sshUser`/`sshKey` fields via `nix.buildMachines`; no global `Host` block — it would redirect interactive `ssh <builder>.d` for all users).
2. §4 assertion 5: note it is implemented as a config-level assertion (no `trusted-users` grant) because `secret-key-files` signs every local registration, making an unsigned-push probe unconstructible from the client; assertion 4 already proves signatures are what the builder accepts.

- [ ] **Step 6: Commit**

Run: `jj describe -m "remote-building: clan service (ssh+signing via vars), amy->bam instance, noctalia toggle, container test" && jj new`
Expected: clean described change.

**Post-merge (user, on hardware):** deploy both machines; on amy run the one-time `sudo nix store sign --all -k $(nix eval --raw .#nixosConfigurations.amy.config.clan.core.vars.generators.remote-building-remote-building.files.\"signing.key\".path)`; smoke: `nix store ping --store ssh://nixremote@bam.d`, trivial `nix build --rebuild` showing `building ... on 'ssh://nixremote@bam.d'`, bar icon flips state ≤5 s.
