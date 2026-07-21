# Hermes VM sharing hardening — design

Date: 2026-07-21. Status: approved, pending implementation.
Scope: `modules/nixos/hermes-microvm.nix`, `modules/nixos/hermes-agent.nix`,
`machines/amy/configuration.nix`.

## Problem

The hermes agent is untrusted, but the VM currently receives far more of the
host than it needs:

1. **rw share of the owner's entire home** (`/home/grmpf`) — read access to
   keys/secrets/projects AND write access for login-time persistence
   (dotfiles), which for a nix trusted-user is effectively host root.
2. **Host clipboard read bridge** — the agent can read the host Wayland
   clipboard at will (passwords transit clipboards).
3. **slirp's `10.0.2.2` host-loopback alias is a wildcard** — every service on
   the host's `127.0.0.1` is one guest `curl` away (simplex daemon, and any
   unauthenticated loopback listener).
4. Generated files are invisible to the user (workspace sits inside the
   namespace-hidden state vault), which motivated sharing a workdir in the
   first place.

## Design

### Shares (per user; `grmpf` today)

| Guest path | Backing (host) | Mode | Host-visible |
|---|---|---|---|
| `/nix/.ro-store` | `/nix/store` | ro + guest rw overlay | n/a (unchanged) |
| `/run/hermes-host` | `…/guest/` (ssh keys, secrets env, tz) | ro | n/a (unchanged) |
| `/var/lib/hermes` | state vault (namespace-hidden) | rw | 🔒 deliberately not (unchanged) |
| `/home/grmpf` | **`~/hermes/home`** (new share) | rw | ✅ |
| `/var/lib/hermes/workspace` | **`~/hermes/workspace`** (new share, nested) | rw | ✅ |
| ~~`/home/grmpf` ⇄ host `/home/grmpf`~~ | **removed** | — | — |

Principle: **persist by purpose, not by mount point.** The guest's mutable
state decomposes into: agent DBs/config (`.hermes`) and `.venv` → stay in the
hidden vault; user-facing artifacts (workspace) and the agent's own home →
visible under `~/hermes/`. Everything else in the guest (`/var`, rootfs,
`/nix/.rw-store`) stays ephemeral tmpfs — inventory confirmed nothing else
worth persisting (guest journal is reachable while running; serial console
lands in the host journal; ad-hoc `nix` installs are covered by the declarative
guest + persistent `.venv`).

Host layout, tmpfiles-provisioned, all uid-1000:

```
~/hermes/
  home/        ⇄ guest /home/grmpf   (agent dotfiles, caches — auditable)
  workspace/   ⇄ guest /var/lib/hermes/workspace  (artifact exchange)
```

Notes:
- The workspace is **one flat directory shared by all sessions** and hermes
  **never GCs it** (verified against the 0.18.2 wheel: only backup snapshots
  are pruned). No auto-cleanup on the host either — the agent may keep
  long-lived project dirs there; deletion is the user's manual call.
- Cross-kernel rule now applies to the user: do not open live SQLite DBs the
  agent creates inside `~/hermes/` while the VM runs.
- Dotfile-planting against the HOST home is dead: the guest home is a separate
  directory.

### Clipboard bridge: removed entirely

Decision: the host clipboard is never shared with the agent — no opt-in
either. Delete the whole mechanism from `hermes-microvm.nix`, not just the
flag: the `clipboard.{enable}` and `clipboardPort` options, the guest
wl-paste shim package, the host `hermes-clipboard-bridge-<user>` socat unit,
the clipboard iptables rules, and the header-comment section. Drop the
`clipboard.enable = …` line from `hermes-agent.nix`. TUI image paste
degrades to "No image found in clipboard".

### Simplex: daemon moves inside the VM

- Remove `SIMPLEX_WS_URL`/`SIMPLEX_ALLOWED_USERS` host-alias wiring from
  `hermes-agent.nix`; remove the `simplex-chat.nix` import from amy.
- Import `simplex-chat.nix` into the guest config instead;
  `SIMPLEX_WS_URL = ws://127.0.0.1:<port>`; `allowedUsers` config moves along.
- Daemon state (SQLite: identity keys, pairings) must persist → lives under
  the vault mount (e.g. `/var/lib/hermes/simplex`; wire the module's state
  dir accordingly).
- **Accepted risk (amber):** simplex's SQLite likely runs WAL on virtiofs and
  cannot be patched like hermes (Haskell binary). Guest-only access keeps it
  safe from the host; the residual FUSE-mmap risk is accepted — worst case is
  re-pairing contacts. Implementation should check for a journal-mode knob
  and use it if one exists.

### Loopback allowlist (guest → host)

Guest-initiated traffic to `10.0.2.2` egresses on the host as uid `microvm`
to `127.0.0.1`. Extend the module's existing `hermes-microvm` iptables chain:

- ACCEPT `-o lo -m owner --uid-owner microvm` to the spaces bridge port(s);
- ACCEPT dport 53 on loopback (slirp DNS via systemd-resolved-style
  resolvers);
- REJECT everything else on loopback for that uid.

Host→guest forwards (ssh, dashboard) are a different direction/uid —
unaffected. Outbound non-loopback internet (LLM endpoints, telegram, SMP)
unaffected.

### Out of scope

Dashboard download-link fixes (see `docs/hermes-dashboard-download-links.md`),
Venus GPU config, the DELETE-journal package patch, state vault mechanics —
all unchanged.

## Migration / deploy notes

- Old workspace content sits in the vault under `state-vault/state/workspace/`;
  the new share mounts over that path, shadowing it. One-time move (as root):
  vault `workspace/*` → `~/hermes/workspace/`, then delete the shadowed dir.
- Moving simplex into the guest starts a **fresh simplex identity** (re-pair
  contacts) unless the host daemon's DB (`/var/lib/simplex-chat`) is manually
  copied into the vault-backed state dir.
- The agent loses sight of the host home; anything it previously referenced
  under `/home/grmpf/...` must now be placed into `~/hermes/` explicitly.

## Verification

- `nix build .#nixosConfigurations.amy.config.system.build.toplevel` builds.
- Runner inspection: home share absent; the two `~/hermes` shares present;
  virtiofsd sources correct.
- Post-deploy smoke: generate a file via the agent → appears in
  `~/hermes/workspace/`; guest `curl 10.0.2.2:<non-spaces-port>` fails,
  spaces MCP still works; simplex pairing works from inside the guest;
  clipboard paste degrades gracefully; host `ls ~/hermes/home` shows agent
  dotfiles.
