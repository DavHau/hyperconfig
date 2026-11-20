# Hermes vault out of the agent's reach

Status: implemented (hyperhermes `modules/core/vault-broker.nix`,
`patches/hermes-vault-broker-client.patch`, check `vault-broker`).
Design reviewed by a security reviewer (approve with changes; all blocking
findings applied, see "Review" below). Part of the vault rework, after
"cards on any site" (`hermes-vault-payment-any-site.patch`).

## Problem

hermes keeps the vault at `<HERMES_HOME>/vault/` (`vault.json.enc`,
Fernet, key in `vault.key` beside it), all owned by the agent's uid. The
terminal tool, `execute_code` and every process the agent starts run as
that uid, so the model could decrypt every card and password with a
five-line script (dave-hermes offered exactly that). The vault only kept
values out of the model's context by convention.

## Facts the design rests on (som, hermes v0.23.0)

- The gateway (`hermes-agent-<u>`) and the dashboard
  (`hermes-dashboard-<u>`, which runs chat sessions in-process) are the
  processes that fill: `browser_vault` resolves the secret in-process and
  writes it over CDP or the Camofox plugin's page backend. Both units'
  MainPID is the hermes python itself (the wrappers exec); NotifyAccess is
  none, so no child can move MainPID. dave-hermes runs one gateway for all
  its profiles (`gateway.multiplex_profiles`). Delegate subagents are
  threads of the gateway.
- Terminal commands, `execute_code`, kernels, MCP servers, cron workers
  (an external worker under a systemd-managed gateway), managed workers
  and `dashboard.turn_isolation`'s compute host are other processes.
- `kernel.yama.ptrace_scope` is 1 and the units are children of pid 1: no
  agent process can ptrace or read the memory of its gateway.
- Core dumps: the units ran with LimitCORE=infinity and systemd-coredump
  gives the owner a read ACL on its processes' cores.
- Writers of the vault: `browser_vault create_login/save_login`,
  `hermes vault add/rm`, the desktop app's vault methods, the
  vault-request page (agent uid).
- Two agents on som had a legacy vault: dave-hermes and thaigersprint.

## Design (as built)

- `hermes-vault-<u>.socket`: `/run/hermes-vault/<u>.sock`, root's socket
  (0666) in root's 0755 directory: the agent can neither replace nor chmod
  it. The broker checks the caller on every request (SO_PEERCRED).
- `hermes-vault-<u>.service` (`vault-broker.py`): `DynamicUser`,
  `StateDirectory=hermes-vault/<u>` under `/var/lib/private` (0700 root:
  the agent cannot traverse it), hermes' own `VaultStore` per home (the
  agent's home, `profiles/<name>`), strict sandboxing (no network, AF_UNIX
  only, ProtectSystem=strict, ProtectHome, ProtectProc, LimitCORE=0).
  Socket activated. One JSON line per connection; 10 s per request, at
  most 4 open requests per process and 32 in all (a deliberate flood from
  many processes of the agent can still delay its own fills: visible, and
  nothing leaks).
  - only the agent's uid; any other uid is refused;
  - `list_items`, `get_meta`, `has_items`, `add_item`, `remove_item`: any
    process of the agent;
  - `resolve_secret`: only when the peer is the current MainPID of
    `hermes-agent-<u>` or `hermes-dashboard-<u>` (systemd asked per
    request), pinned with SO_PEERPIDFD so a recycled pid cannot pass. A
    terminal command, script, kernel or worker is refused and logged.
  - every resolve, add and remove is logged (item id, kind, label, unit;
    never a value); resolves capped per hour (60 logins, 30
    cards+addresses); 1000 items per home, 8 KiB per item, 32 extra
    homes, 16 concurrent connections, 10 s per request;
  - no key, export or decrypt operation exists; `import` (the
    migration's merge) is root's only.
- Client (`hermes-vault-broker-client.patch`): `VaultStore` uses the
  broker exactly when root's marker `/run/hermes-vault/<u>.on` exists (no
  environment switch: the agent's `.env` is loaded with override and could
  point the gateway at a socket of its own). One connection per request,
  close-on-exec; a server running as the caller's own uid is refused; an
  unreachable broker, or an account the host cannot name, fails closed (no fallback that would mint a new
  agent-readable key). `hermes vault key` reports the broker,
  `key migrate` refuses, profile clones copy no key.
- `LimitCORE=0` on the gateway and dashboard units (hard limit).

## Migration

`hermes-vault-migrate-<u>.service`, a sandboxed root oneshot the gateway,
dashboard and vault-request page want and are ordered after, so it runs
before every (re)start of each of them, auto-restarts included (nothing to
do when no legacy files exist). Bounded: 60 s for the unit, 10 s for the
lock; a failure never keeps the agent's units down.

1. every path opened with O_NOFOLLOW component by component; each file
   (the lock too) a regular file of the agent's uid with one link, 256 KiB
   at most; links, FIFOs and hard links the agent planted are refused
   (logged, left alone); the legacy `.vault.lock` is taken, or the home is
   skipped if a process of the agent holds it;
2. backup as read to `/root/hermes-vault-backup/<u>/<home>/<time>/`
   (0700/0600 root, with its sha256; the same content is not backed up
   twice; per home the first and the 4 newest are kept: the agent can
   replant and restart at will, but never push out the real one).
   Retention: until Dave confirms the migrated items work, then delete
   them (they hold plaintext-equivalent data);
3. decrypt with the legacy key, root-only `import` into the broker
   (records whose ids the broker lacks, same shape and quotas as an add;
   ids kept, so handles stay valid; on an id collision the broker's record
   wins and the legacy one survives only in the backup);
4. only if the broker holds every legacy id: remove `vault.json.enc`, then
   `vault.key` (that order), through the directory handle and only if
   still the files that were read.

Any doubt leaves the legacy files untouched, the agent starts on the
broker without those items, the next start retries. A keychain-mode vault
(`vault.keyref`) is skipped: root cannot reach the owner's Secret Service.

Before the first deploy, both legacy vaults on som were also backed up by
hand (root 0600, `/root/hermes-vault-backup/<u>/pre-broker-*`).

## What it closes, what stays

Closed: reading the key or ciphertext from the agent's uid (files, cores);
resolving a value from a terminal command, script, kernel, MCP server or
worker; skills that "decrypt the vault".

Residual, by design:
- Code inside the gateway can resolve. An agent without `lockedConfig`
  (every agent with the browser: lockedConfig cannot be combined with it)
  can put a plugin into its `plugins/` (or `hooks/`, `patches/`, a native
  FTS extension) and `reload-plugins` on its own gateway socket, with no
  restart. The broker stops the five-line script and the key theft, not a
  determined agent; its per-resolve log and hourly caps make a harvest
  slow and visible.
- The browser runs as the agent's uid (Camofox key in its `.env`): after a
  fill the agent can read the filled field back. A login fill needs no
  human consent, so every saved password stays readable one at a time this
  way; a card only after Dave confirmed that fill.
- Consent is enforced in the gateway, not the broker.
- Root reads everything (backups included).
- The OLD key and ciphertext stay readable by the agent in som's ZFS
  snapshots (`/.zfs/snapshot/...`, auto-snapshots up to monthly) until
  they expire. Items saved before the migration (dave-hermes: two cards;
  thaigersprint's items) must be treated as exposed: replace the cards,
  rotate saved passwords, or accept it. New items are safe.
- Fills from processes other than the gateway/dashboard main process are
  refused: cron jobs (external worker), managed workers,
  `dashboard.turn_isolation`, `hermes chat`/TUI started in a shell. None
  use the vault on som today.
- `hermes backup`/import and profile rename/delete no longer carry the
  vault (it left HERMES_HOME); a renamed profile loses access to its items
  (they stay in the broker under the old name).

## Review

Implementation security review: request changes, then fixed: the agent
could stall the migration (and its gateway's start, and a deploy) with a
FIFO or a held lock; `import` bypassed the quotas and the agent could
replant + restart to fill root's disk; a passwd lookup failure fell back to
files; a slow client could take every broker slot; the migrate unit ran as
unsandboxed root. All fixed and tested (FIFO, held lock, file links, hard
link). Delta review: approve with nits (applied: doc wording, a new
agent's first start, the first backup kept, unique backup names; tests for
the import quota and the request deadline).

Design security review (approve with changes). Applied: LimitCORE=0 on the units;
migration as an ordered root oneshot with the legacy lock held; no symlink
following as root; ZFS snapshot exposure stated; residual rewritten; root
marker instead of an env switch, impostor check, fail closed, one
connection per request; uid check on every request with a root-owned
socket; SO_PEERPIDFD; audit log and caps; delete order; keychain skip;
both legacy vaults. Not done: PYTHONNOUSERSITE (user site is already off
in the store python), moving the venv off the gateway's PATH (no exec
through PATH in the MainPID today).

## Tests

Container check `vault-broker`:
- legacy vaults (home + a profile) migrate: same ids/labels/kinds, legacy
  files gone, backups 0600 root in 0700, new key differs, a second start
  changes nothing; planted tricks are refused with the legacy files left
  in place and the start bounded: a vault/ link to root's files, a
  vault.key link, a hard-linked ciphertext, a FIFO lock, a held lock
  (migrated once released);
- the agent's uid cannot list the state dir or read key/ciphertext, no
  card number in plain anywhere, cannot chmod the socket or remove the
  marker; from a shell it lists, adds, removes, and resolve is refused;
- the gateway unit's main process resolves (digest of the card matches),
  a child of it is refused; resolves are logged with the unit;
- another agent's uid is refused; LimitCORE=0 on the units.

Also: `vault-request` (a card saved through the page lands in the broker),
`browser` (the real fills run from a driver unit allowed via
`vaultBroker.fillUnits`), `vault-payment-frames` (the client's unit tests).
