# Hermes VM Sharing Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink what the hermes VM receives from the host to exactly what it needs: no host home, no clipboard, no loopback wildcard; visible `~/hermes/{home,workspace}` exchange dirs; simplex daemon moves inside the guest.

**Architecture:** All changes concentrate in `modules/nixos/hermes-microvm.nix` (guest shares, options, firewall, host units) with small edits to `modules/nixos/hermes-agent.nix` (consumer config) and `machines/amy/configuration.nix` (drop host simplex). Spec: `docs/2026-07-21-hermes-vm-sharing-hardening-design.md`.

**Tech Stack:** NixOS module system, microvm.nix (qemu + virtiofs + slirp), iptables owner-match, systemd bind mounts.

## Global Constraints

- Verification for every task: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link` MUST succeed (warning "Git tree … is dirty" is normal).
- Line numbers below reference the file state at change `4eb5b996`; re-locate by the quoted code if drifted. NEVER leave dangling references — after each removal, `grep` for the removed symbol must return zero hits in `modules/`.
- The state vault, DELETE-journal package patch, Venus GPU config, ssh/dashboard plumbing are OUT OF SCOPE — do not touch.
- No formatters, no project-wide test suites.
- Do not run jj/git (parent session owns version control).

## Dependency Map

All tasks modify `modules/nixos/hermes-microvm.nix` — file contention forces serial execution even though only Task 5 has a true interface dependency.

- Task 1: no logical dependencies
- Task 2: no logical dependencies
- Task 3: no logical dependencies
- Task 4: no logical dependencies
- Task 5: depends on 1–4 (verifies their combined result)

Waves (serialized due to single-file contention):
1. Task 1
2. Task 2
3. Task 3
4. Task 4
5. Task 5

---

### Task 1: Remove the clipboard machinery entirely

**Files:**
- Modify: `modules/nixos/hermes-microvm.nix` (header ~30-36, defs ~126-175, guest pkgs :696, firewall :873-876, shim env :741-751, options :1012-1015 + :1027-1029, host unit :1152-1167)
- Modify: `modules/nixos/hermes-agent.nix:92-97`

**Interfaces:**
- Consumes: nothing
- Produces: module without `clipboard`/`clipboardPort` options (Task 5 verifies zero references)

**Depends on:** none

- [ ] **Step 1: Delete the clipboard bullet from the module header** (lines ~30-36: `#   - clipboard (per-user opt-in \`clipboard.enable\`): …` through `…forwards over ssh.`). Delete the whole bullet.

- [ ] **Step 2: Delete both script definitions in the `let` block**: the `clipboardShimFor = ucfg: pkgs.writeShellScriptBin "wl-paste" ''…''` binding (~line 131, including its lead comment block starting `# Guest-side \`wl-paste\` for the clipboard bridge:` at ~126) and the `clipboardServer = user: ucfg: pkgs.writeShellScript "hermes-clipboard-server-${user}" ''…''` binding (~line 154, including its lead comment).

- [ ] **Step 3: Remove the guest package reference** (line ~696). Change:

```nix
    environment.systemPackages = [ pkgs.socat ]
      # vulkaninfo/vkcube for smoke-testing venus
      ++ lib.optionals cfg.gpu.enable [ pkgs.vulkan-tools ]
      ++ lib.optional ucfg.clipboard.enable (clipboardShimFor ucfg);
```
to:
```nix
    environment.systemPackages = [ pkgs.socat ]
      # vulkaninfo/vkcube for smoke-testing venus
      ++ lib.optionals cfg.gpu.enable [ pkgs.vulkan-tools ];
```

- [ ] **Step 4: Remove the firewall block** (lines ~873-876):

```nix
    ${lib.optionalString ucfg.clipboard.enable ''
      iptables -w -A hermes-microvm -p tcp --dport ${toString ucfg.clipboardPort} -m owner --uid-owner microvm -j RETURN
      ${ownerOnlyRules ucfg.clipboardPort ucfg.uid}
    ''}
```

- [ ] **Step 5: Stop forwarding WAYLAND_DISPLAY in the `hermes` shim** (lines ~741-751). Replace the comment + loop:

```nix
    # COLORTERM/LANG/LC_ALL (TUI colors + UTF-8 glyphs). Embed them into
    # the remote command, shell-quoted. WAYLAND_DISPLAY gates hermes's
    # wayland clipboard path in the guest (served by the bridged wl-paste
    # shim, which ignores the value).
    env_exports=""
    for v in COLORTERM LANG LC_ALL WAYLAND_DISPLAY; do
```
with:
```nix
    # COLORTERM/LANG/LC_ALL (TUI colors + UTF-8 glyphs). Embed them into
    # the remote command, shell-quoted. Deliberately NOT WAYLAND_DISPLAY:
    # the host clipboard is never bridged into the VM; without the variable
    # hermes's clipboard path stays disabled and paste degrades to
    # "No image found in clipboard".
    env_exports=""
    for v in COLORTERM LANG LC_ALL; do
```

- [ ] **Step 6: Delete the options** — `clipboardPort = mkOption { … };` (~1012-1015) and the `clipboard = { enable = mkEnableOption …; };` submodule attr (~1027-1029).

- [ ] **Step 7: Delete the host bridge unit** — the whole `"hermes-clipboard-bridge-${user}" = lib.mkIf ucfg.clipboard.enable { … };` attr (~1152-1167, including its lead comment `# clipboard bridge: guest wl-paste shim -> slirp …`).

- [ ] **Step 8: Remove the consumer line in hermes-agent.nix** (lines 92-97). Delete:

```nix
      # TUI image paste: bridge the host Wayland clipboard into the guest
      # (read-only wl-paste shim over slirp). Gated on "has a desktop
      # session"; without a session every paste degrades to the normal
      # "No image found in clipboard".
      clipboard.enable = config.services.pipewire.enable;
```

- [ ] **Step 9: Verify zero references and build**

Run: `grep -rn clipboard modules/nixos/hermes-microvm.nix modules/nixos/hermes-agent.nix`
Expected: only the new Step-5 comment mentioning "clipboard" degradation (no `clipboardPort`, `clipboardShimFor`, `clipboardServer`, `clipboard.enable`).
Run: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link`
Expected: success.

---

### Task 2: Replace the host-home share with `~/hermes/{home,workspace}`

**Files:**
- Modify: `modules/nixos/hermes-microvm.nix` (header ~6-11 and caveats ~50-53, shares ~446-451, guest service ~660-668, tmpfiles ~1183-1190)

**Interfaces:**
- Consumes: nothing
- Produces: share tags `hermes-home`, `hermes-workspace`; host dirs `/home/<user>/hermes/{home,workspace}` (Task 5 verifies in the runner)

**Depends on:** none

- [ ] **Step 1: Replace the home share block** (~446-451). Change:

```nix
        {
          proto = "virtiofs";
          tag = "home";
          source = "/home/${user}";
          mountPoint = "/home/${user}";
        }
```
to:
```nix
        {
          # Guest home: persistent, host-visible under ~/hermes/home. The
          # agent is untrusted — it never sees the owner's real home; its
          # own home is a separate, auditable directory. uid 1000 on both
          # sides (virtiofsd maps 1:1).
          proto = "virtiofs";
          tag = "hermes-home";
          source = "/home/${user}/hermes/home";
          mountPoint = "/home/${user}";
        }
        {
          # Artifact exchange: one flat dir shared by ALL hermes sessions,
          # never GC'd by hermes — cleanup is the owner's manual call.
          # Mounted over the state share (nested). Do not open live SQLite
          # DBs the agent creates here while the VM runs (cross-kernel
          # locking is not coordinated over virtiofs).
          proto = "virtiofs";
          tag = "hermes-workspace";
          source = "/home/${user}/hermes/workspace";
          mountPoint = guestWorkspace;
        }
```

- [ ] **Step 2: Order the gateway after the workspace mount.** In the guest `systemd.services.hermes-agent` override that sets `WorkingDirectory = guestWorkspace;` (~line 660-668), add to the same block:

```nix
        unitConfig.RequiresMountsFor = [ guestWorkspace ];
```
(If an `unitConfig` attr already exists there, merge the key into it.)

- [ ] **Step 3: Add host tmpfiles rules.** In the per-user tmpfiles list (after the `"d ${shareSourceDir user}/state 0700 root root - -"` line, ~1188):

```nix
        "d /home/${user}/hermes 0755 ${user} users - -"
        "d /home/${user}/hermes/home 0700 ${user} users - -"
        "d /home/${user}/hermes/workspace 0755 ${user} users - -"
```

- [ ] **Step 4: Update the module header.** Rewrite the stale claims:
  - Lines ~6-11: replace `…so the virtiofs-shared home keeps consistent ownership. The guest gets the host's /nix/store read-only, a namespace-hidden virtiofs share for HERMES state (see below), the owner's home read-write, and passwordless sudo (parity with the old container's self-modification support).` — the guest no longer gets the owner's home. New text:

```
# the same name/uid as the host user. The guest gets the host's /nix/store
# read-only, a namespace-hidden virtiofs share for HERMES state (see
# below), a persistent guest home + artifact workspace exposed on the host
# as ~/hermes/{home,workspace}, and passwordless sudo inside the guest.
```
  - Caveats block (~50-53): replace the `the guest is trusted with the owner's HOST account: rw home means a hostile agent can plant dotfiles…` bullet with:

```
#   - the guest never sees the owner's real home. Its persistence surface
#     is ~/hermes/{home,workspace} (owner-auditable) plus the hidden state
#     vault; host dotfile-planting via a shared home is no longer possible.
```

- [ ] **Step 5: Build**

Run: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link`
Expected: success.

---

### Task 3: Move the simplex daemon into the guest

**Files:**
- Modify: `modules/nixos/hermes-microvm.nix` (guest imports ~370s, env merge ~584, new options after `gpu` ~1000, guest config)
- Modify: `modules/nixos/hermes-agent.nix:33` (drop `simplexCfg`), `:101-108` (env block), add `simplex.enable`
- Modify: `machines/amy/configuration.nix:18` (import), `:29` (enable)
- Modify: `modules/nixos/simplex-chat.nix:15-16` (stale comment)

**Interfaces:**
- Consumes: nothing
- Produces: option `services.hermes-microvm.simplex.{enable,allowedUsers}`; guest daemon on `127.0.0.1:5225`; state at `/var/lib/hermes/simplex` (vault-backed)

**Depends on:** none

- [ ] **Step 1: Add module options** (in `options.services.hermes-microvm`, after the `gpu` block):

```nix
    simplex = {
      enable = mkEnableOption "a SimpleX Chat daemon inside each guest (state on the vault share)";
      allowedUsers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "SIMPLEX_ALLOWED_USERS passed to hermes (contactIds or display names).";
      };
    };
```

- [ ] **Step 2: Wire the guest.** In `guestConfig`, add `./simplex-chat.nix` to `imports`, and add alongside the other guest config:

```nix
    # SimpleX daemon lives INSIDE the guest (no host loopback exposure).
    # Its SQLite state must persist -> bind /var/lib/simplex-chat onto the
    # vault share. Known amber risk: simplex runs its own SQLite (likely
    # WAL) on virtiofs; guest-only access keeps the host out, the residual
    # FUSE-mmap hazard is accepted — worst case is re-pairing contacts.
    services.simplex-chat-daemon = lib.mkIf cfg.simplex.enable {
      enable = true;
      allowedUsers = cfg.simplex.allowedUsers;
    };
    fileSystems."/var/lib/simplex-chat" = lib.mkIf cfg.simplex.enable {
      device = "${guestStateDir}/simplex";
      options = [ "bind" ];
    };
```
Note: `simplex-chat.nix` hardcodes `/var/lib/simplex-chat` (StateDirectory) — the bind redirects it onto the vault; systemd's `StateDirectory=` chowns the mounted view at service start, and the fstab generator orders the bind after the vault mount via the device path.

- [ ] **Step 3: Create the vault subdir from the host.** In `vaultBindScript` (the `hermes-vault-bind-<user>` script), after the existing `install -d … state-vault/state` line, add:

```nix
    install -d -m 0755 ${baseDir user}/state-vault/state/simplex
```

- [ ] **Step 4: Inject the env into hermes.** At the guest `services.hermes-agent` block (~584), change:

```nix
      environment = cfg.environment // ucfg.environment;
```
to:
```nix
      environment = cfg.environment // ucfg.environment
        // lib.optionalAttrs cfg.simplex.enable (
          {
            SIMPLEX_WS_URL = "ws://127.0.0.1:${toString config.services.simplex-chat-daemon.port}";
          }
          // lib.optionalAttrs (cfg.simplex.allowedUsers != [ ]) {
            SIMPLEX_ALLOWED_USERS = lib.concatStringsSep "," cfg.simplex.allowedUsers;
          }
        );
```
(`config` here is the GUEST config argument of `guestConfig` — the daemon port option exists because of the Step-2 import.)

- [ ] **Step 5: Update hermes-agent.nix.** Delete the `simplexCfg = config.services.simplex-chat-daemon;` let-binding (line 33) and the whole `environment = lib.optionalAttrs simplexCfg.enable (…)` block (lines ~98-108 with its comment). Add under `services.hermes-microvm`:

```nix
    # SimpleX runs inside the VM; pairing is unchanged (journalctl inside
    # the guest shows the simplex:/ address link).
    simplex.enable = true;
```

- [ ] **Step 6: Update amy.** In `machines/amy/configuration.nix` delete the import `../../modules/nixos/simplex-chat.nix` (line ~18) and `services.simplex-chat-daemon.enable = true;` (line ~29).

- [ ] **Step 7: Fix the stale comment in simplex-chat.nix** (lines 15-16). Replace:

```
# Hermes side: hermes-agent.nix injects SIMPLEX_WS_URL into the hermes
# microvm; the guest reaches the daemon via slirp's host alias (10.0.2.2).
```
with:
```
# Hermes side: this module runs INSIDE the hermes microvm guest
# (services.hermes-microvm.simplex.enable); hermes reaches it on the
# guest's own 127.0.0.1.
```

- [ ] **Step 8: Journal-mode knob check (spec requirement).** Run `nix build` of the simplex package if needed and `simplex-chat --help 2>&1 | grep -iE 'journal|wal|sqlite'` (or read `modules/nixos/simplex-chat-package.nix` upstream docs). If a journal-mode flag exists, add it to `ExecStart` in `simplex-chat.nix` forcing DELETE/rollback and update the Step-2 comment; if not (expected), leave the amber-risk comment as written and note the finding in the task report.

- [ ] **Step 9: Verify and build**

Run: `grep -rn 'simplex' machines/amy/configuration.nix modules/nixos/hermes-agent.nix`
Expected: only `simplex.enable = true;` (+ comment) in hermes-agent.nix and the untouched `simplexPlatformFixed` plugin patch block; nothing in amy.
Run: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link`
Expected: success.

---

### Task 4: Loopback allowlist for the guest (uid `microvm`)

**Files:**
- Modify: `modules/nixos/hermes-microvm.nix` (firewallRules ~866-877, extraCommands/extraStopCommands ~1054-1065, header caveat ~41-43)

**Interfaces:**
- Consumes: nothing
- Produces: default-deny loopback policy for uid `microvm` (spaces ports + DNS only)

**Depends on:** none

- [ ] **Step 1: Append the allowlist tail to `firewallRules`** (~866-877). Change the binding to concatenate a trailer after the per-user rules:

```nix
  firewallRules = lib.concatStrings (lib.mapAttrsToList (user: ucfg: ''
    ${ownerOnlyRules ucfg.sshPort ucfg.uid}
    ${ownerOnlyRules ucfg.dashboardPort ucfg.uid}
    ${lib.optionalString ucfg.spacesGateway.enable ''
      iptables -w -A hermes-microvm -p tcp --dport ${toString ucfg.spacesPort} -m owner --uid-owner microvm -j RETURN
      ${ownerOnlyRules ucfg.spacesPort ucfg.uid}
    ''}
  '') cfg.users) + ''
    # Guest -> host loopback allowlist: everything a guest sends to slirp's
    # 10.0.2.2 egresses here as uid microvm. The per-user spaces-bridge
    # RETURNs above are the only sanctioned services; DNS stays open for
    # slirp's resolver forwarding; the rest of the host's loopback is
    # rejected (it used to be a wildcard).
    iptables -w -A hermes-microvm -p tcp --dport 53 -m owner --uid-owner microvm -j RETURN
    iptables -w -A hermes-microvm -p udp --dport 53 -m owner --uid-owner microvm -j RETURN
    iptables -w -A hermes-microvm -m owner --uid-owner microvm -j REJECT
  '';
```

- [ ] **Step 2: Hook UDP into the chain.** The chain currently only sees TCP. In `networking.firewall.extraCommands` (~1054-1060) add after the existing TCP hook:

```nix
      iptables -w -C OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
        || iptables -w -A OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm
```
and in `extraStopCommands` (~1061-1065) add before the flush:

```nix
      iptables -w -D OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
```

- [ ] **Step 3: Update the header caveat** (~41-43). Replace the bullet `all VMs' qemu processes run as the shared \`microvm\` user, so one user's *guest* could reach another user's spaces bridge port (and host loopback services like the simplex daemon);` with:

```
#   - all VMs' qemu processes run as the shared `microvm` user; the
#     loopback allowlist (spaces ports + DNS, REJECT otherwise) keeps
#     guests off arbitrary host loopback services, but one user's guest
#     can still reach ANOTHER user's spaces bridge port;
```

- [ ] **Step 4: Build**

Run: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link`
Expected: success.

---

### Task 5: End-to-end verification + doc status

**Files:**
- Modify: `docs/2026-07-21-hermes-vm-sharing-hardening-design.md:3` (status line)

**Interfaces:**
- Consumes: everything Tasks 1–4 produced
- Produces: verified system

**Depends on:** 1, 2, 3, 4

- [ ] **Step 1: Full build**

Run: `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link --print-out-paths`
Expected: success; note the store path `$SYS`.

- [ ] **Step 2: Runner inspection** — build the VM runner and check the shares:

Run:
```sh
runner=$(nix build .#nixosConfigurations.amy.config.microvm.vms.hermes-grmpf.config.config.microvm.declaredRunner --no-link --print-out-paths)
grep -hE 'shared-dir' $(grep -ohE '/nix/store/[a-z0-9]{32}-virtiofsd-[a-z-]+' $runner/bin/virtiofsd-run | sort -u)
```
Expected: four shared-dirs — `/nix/store`, `/run/hermes-microvm-shares/grmpf/state`, `/home/grmpf/hermes/home`, `/home/grmpf/hermes/workspace`, plus the ro `…/guest` host-config dir; NO bare `/home/grmpf` source.

- [ ] **Step 3: Rendered units** — from `$SYS`:

Run: `grep -rl clipboard $SYS/etc/systemd/system/ | head`
Expected: no `hermes-clipboard-bridge-*` unit.
Run: `grep -o 'simplex-chat.service' $SYS/etc/systemd/system/multi-user.target.wants/ -r | head -1`
Expected: empty (daemon is NOT on the host).
Run: guest system: `g=$(grep -ohE '/nix/store/[a-z0-9]{32}-nixos-system-hermes-grmpf[^ "'"'"']*' $runner/bin/microvm-run | head -1); ls ${g%/init}/etc/systemd/system/multi-user.target.wants/ | grep simplex`
Expected: `simplex-chat.service` (daemon IS in the guest).
Run: `grep -A2 'uid-owner microvm -j REJECT' $SYS/etc/…` — locate the firewall script via `grep -rl 'hermes-microvm' $SYS/etc/systemd/system/firewall.service` and confirm the tail rules (two dport-53 RETURNs then the REJECT) render after the per-user rules.

- [ ] **Step 4: Repo hygiene**

Run: `grep -rn 'clipboardPort\|clipboardShimFor\|clipboardServer\|SIMPLEX_WS_URL.*10\.0\.2\.2' modules/ machines/`
Expected: zero hits.

- [ ] **Step 5: Update spec status** — change line 3 of the design doc to `Status: implemented (this plan); pending deploy.`

- [ ] **Step 6: Report post-deploy smoke tests** (not executable at build time — hand to the user):
  - generate a file via the agent → appears in `~/hermes/workspace/`
  - guest: `curl -m2 http://10.0.2.2:5225` FAILS (rejected), spaces MCP still works, `curl` to any other host-loopback port fails
  - guest: `journalctl -u simplex-chat | grep 'simplex:/'` shows the pairing address (fresh identity unless the old host DB at `/var/lib/simplex-chat` was copied into `state-vault/state/simplex` first)
  - one-time migration: move old vault `workspace/*` into `~/hermes/workspace/` (the new mount shadows the old dir)
  - host: `ls ~/hermes/home` shows agent dotfiles after first boot
