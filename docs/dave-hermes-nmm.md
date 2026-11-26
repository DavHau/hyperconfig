# dave-hermes works on nmm (asof-agents)

Dave's request (2026-11-21): steer the asof/nmm project from dave-hermes
instead of only through afk inside the container, and keep the afk route
open. Decision D28 (2026-11-21): no skill import from the container; one
static skill, only in a dedicated hermes profile; the login stays `agent`.

## Status

| part | where | status |
|---|---|---|
| ssh key `dave-hermes-nmm-ssh` (clan var, owner dave-hermes) | `machines/som/dave-hermes-nmm.nix` | landed, generated |
| `ssh asof-agents` for dave-hermes (user agent, own key, guest host key pinned in the module, from som's stable `::c0de:ba5e`) | same file, ssh_config `Match` block | landed |
| hermes profile `nmm` in dave-hermes | same file, `dave-hermes-nmm-profile.service` | landed |
| skills `nmm` (seeded once, then the agent's) and `nmm-tools` (managed, rewritten) in profile `nmm` only | hyperhermes `profileSkills` (`hyperhermes/modules/core/profile-env.py`), sources `machines/som/dave-hermes-nmm/{nmm,nmm-tools}/` | landed, needs a som deploy |
| `remote asof-agents run/put/get/ro/pane/steer/task-status` | hyperhermes `remotes` (`hyperhermes/modules/core/remotes.nix`), target in `machines/som/dave-hermes-nmm.nix` | landed, needs a som deploy |
| key authorized for `agent` in asof-agents | nmm's flake | **waits: Dave adds the line below; the swarm deploys agents** |
| root in asof-agents and asof (Dave, 2026-11-26): key `dave-hermes-nmm-root-ssh` (clan var, owner dave-hermes, 0400, som only), `from=` som's `::c0de:ba5e`, no other restriction; aliases `asof-agents-root`/`asof-root`, `remote` targets of the same names (cwd /root) | `machines/som/dave-hermes-nmm.nix`; keys placed by container-slots' `rootKeys` (`container-slot-<slot>-root-keys.service`, a marked block in the guest's `/root/.ssh/authorized_keys`, no slot restart); asof's host key `machines/som/slot-host-keys.nix` | landed; needs `clan vars generate som --generator dave-hermes-nmm-root-ssh` and a som deploy |

History: a first version exported afk's skills and nmm's trunk text from
the container into a global skill dir (aa7d5309). Its security review found
a root code-execution path through the swarm's git config and a
frontmatter bypass; it was un-imported (30e2fd0c) and, per D28, dropped:
nothing is read from the container any more.

## Using it

The `nmm` and `nmm-tools` skills live only in the profile `nmm`;
dave-hermes' default and other profiles don't see them. `nmm` is seeded
from hyperconfig once, when the profile has no `skills/nmm/`, and from
then on belongs to the agent (and its background skill review), like any
skill it writes; hyperconfig never rewrites it. `nmm-tools` documents the
`remote` CLI and the swarm recipes and is rewritten on every profile sync
(gateway start, profile change); the agent doesn't edit it. Dave picks the
profile in the desktop/web app's profile picker, or on som with
`hermes -p nmm` (as dave-hermes). The profile was created with `hermes
profile create nmm` (same model as the agent, hermes' own layout, a SOUL
line naming its purpose); after that it is Dave's: only
`skills/nmm-tools/` is rewritten.

The ssh login itself is per account, not per profile: every profile and
cron job of dave-hermes can run `ssh asof-agents`; only the skill's
guidance is limited to profile `nmm`.

## nmm change (Dave's repo, deployed by the swarm)

In nmm `machines/agents/configuration.nix`, for `users.agent` only (not
root):

    from="2405:9800:b901:94e3::c0de:ba5e",restrict,pty <hyperconfig vars/per-machine/som/dave-hermes-nmm-ssh/key.pub/value>

`machines/agents/**` is `[second-review]` in nmm's `swarm/gates.toml`: Dave
commits it or files it as a swarm task; `swarm deploy agents` applies it
(a switch, no container restart).

## Remaining risks (accepted by Dave)

- **Root in both swarm slots.** dave-hermes (and every profile and cron
  job of it, and whatever injects text into it) has full root in
  asof-agents and asof: the owner signing key, the swarm db, and asof's
  own account secrets. The skill forbids printing or moving secrets and
  limits owner-card answers to cards from Dave's own requests; nothing
  enforces it. Revoke: set `rootKeys = [ ]` for those slots and deploy
  som; the block is emptied on the switch. Removing the setting instead
  (null) leaves the last block in place.

- **Owner powers.** `agent` is the swarm owner: `swarm owner
  approve|reject|answer`, `approve-change`, `pause`/`resume`, `trial
  keep|revert`, owner deploys, and it owns the repo, the swarm db and every
  session's workspace. The skill forbids owner actions unless Dave names
  the card in his own message; nothing enforces it. (Signed owner-card
  answers need `/var/lib/swarm-owner/ed25519.key`, readable only by root
  and swarm-owner and not installed today, so those may fail for `agent`;
  pause/resume, trials, merge queue, deploys and the repo/db rights
  don't.) (A separate account
  without owner rights, or a forced-command allowlist, would; both need
  an nmm change.)
- **Shared jj op log.** One op log serves every session; the skill tells
  the agent to use its own workspace and never undo/restore/abandon
  others' work.
- **Injection through text read over ssh.** AGENTS.md, repo skills, task
  bodies, transcripts and command output are written by unattended swarm
  agents, and dave-hermes reads them with approvals off, unsandboxed,
  with vault-ro and its wallet in reach. The skill marks them as data;
  that reduces, not removes, prompt injection. A dedicated agent without
  vault, wallet or Dave's channels would bound it.
- The pinned host key: if the guest's key is regenerated, the login fails
  until the module is updated (ssh-keyscan the guest, compare with its
  `/etc/ssh/ssh_host_ed25519_key.pub`).

## Verify (after the som deploy)

    ssh som.d systemctl status dave-hermes-nmm-profile
    ssh som.d "runuser -u dave-hermes -- hermes -p nmm skills list" | grep nmm   # nmm, nmm-tools
    ssh som.d "runuser -u dave-hermes -- hermes skills list" | grep -w nmm       # absent
    # as dave-hermes (its unit PATH has `remote`):
    remote asof-agents run -- jj st
    remote asof-agents put /etc/hostname x && remote asof-agents get x
    remote asof-agents ro df -h /
    remote asof-agents task-status <task-id>; remote asof-agents pane <task-id> 20
    # after the nmm change:
    ssh som.d "runuser -u dave-hermes -- ssh asof-agents true"
