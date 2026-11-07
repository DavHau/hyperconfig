# som entity storage: small backed-up space, large scratch space

## Problem

On 2026-11-05 som's pool (zroot, 1.8T) filled to 0 B. Users, hermes
agents and container slots all wrote into the auto-snapshotted
`zroot/root`, so every rebuildable byte they churned (caches, build
trees, experiment scratch, docker images) was also held by snapshots
(613G of them). Nothing limited any single entity, and nothing warned.

## Goal

Every entity that uses som (human user, hermes agent, container slot)
gets:

- a backed-up space (snapshotted) with a hard 20G limit by default, and
- a larger scratch space that is not snapshotted, with its own limit.

Entities organize their own data; we make the right placement the
default for common tools, tell agents through a skill and slot deployers
through the onboarding text, and place our declarative services
ourselves. Valuable slot data (asof's experiments and runs, git repos)
stays backed up.

## Mechanism

ZFS snapshots are per dataset and cannot exclude directories, but a
dataset mounted at a directory takes that directory out of its parent's
snapshots. So "exclude ~/.cache" is "mount a scratch dataset at
~/.cache".

Limits are `refquota` on backed-up datasets (snapshots do not count;
deleting frees quota immediately; snapshot overhead is watched by the
pool alerts) and `quota` on scratch parents (covers their children).
Hitting a limit fails that entity's writes with EDQUOT/ENOSPC; the
rest of the machine keeps working.

All new datasets live under the encrypted `zroot/root` so they inherit
its key and its `com.sun:auto-snapshot` setting (`nobackup` turns it
off).

## Layout

Users and agents (`isNormalUser` accounts, opted in per user):

| Dataset | Mountpoint | Snapshots | Limit |
|---|---|---|---|
| `zroot/root/home/<u>` | `/home/<u>` | yes | refquota 20G |
| `zroot/root/nobackup/scratch/<u>` | `/home/<u>/scratch` | no | quota 200G (whole subtree) |
| `zroot/root/nobackup/scratch/<u>/cache` | `/home/<u>/.cache` | no | in parent |
| `zroot/root/nobackup/scratch/<u>/containers` | `/home/<u>/.local/share/containers` | no | in parent |
| `zroot/root/nobackup/scratch/<u>/sbox-state` | `/home/<u>/.local/state/sbox` | no | in parent |

Container slots (host side, no guest cooperation needed; guest uid 0 is
the slot's `uidBase` on the host):

| Dataset | Host mountpoint | Snapshots | Limit |
|---|---|---|---|
| `zroot/root/slots/<s>` | `/var/lib/nixos-containers/<s>` | yes | refquota, per slot |
| `zroot/root/nobackup/slots/<s>` | `/var/lib/slot-scratch/<s>` | no | quota, per slot |

Subdirectories of the scratch dataset are bound into the guest at
`/scratch`, `/var/tmp`, `/var/cache`, `/var/lib/docker`,
`/var/lib/containers`, `/root/.cache`, plus per-slot `scratchPaths`
declared in this repo (e.g. asof-agents' `/home/agent/.cache`). The
guest's `/tmp` already lives on the host's non-snapshotted `/tmp`.

The slot guest module (`slot`) sets the same tool defaults
inside the guest and binds `~/.cache` of named guest users onto
`/scratch`; the host-side binds work without it.

## Tool defaults

System-wide variables point each tool's churn into `~/.cache` (scratch):
cargo's `build-dir` and sccache (already there), pip, uv, Hugging Face,
torch, playwright, ccache and nix (already there by XDG default), plus
explicit `GOPATH`, npm/pnpm caches and store, bun, gradle, maven,
ollama models. Hermes agent units, which have no PAM session, get the
same variables. Still in the repo: final `./target`, `.venv`,
`node_modules`; the agent skill tells agents to keep large outputs in
`~/scratch`.

## Rollout

Gradual, one entity at a time, verified after each:

1. Disable docker on som (done separately).
2. Modules: entity storage (users/agents), slot storage, tool defaults
   plus agent skill, a per-quota 80 % alert. Deployed with no entity
   opted in.
3. Migrate one small user or agent; verify (`zfs list`, `df ~`, the
   agent's services, snapshot exclusion).
4. Remaining users and agents, except dave-hermes.
5. One small agent slot, then asof-agents, mm, asof (largest limits;
   runs, experiments and git stay in the snapshotted root).
6. dave-hermes last.

A migration never shadows data: the reconciler only creates a dataset
over an empty (or absent) directory; a migration tool copies existing
data in with the entity's services stopped, keeps the old tree until
it is verified, and refuses when the backed-up part exceeds its limit
unless directories are moved to scratch explicitly (left behind as
symlinks) or the entity gets a larger limit in config.
