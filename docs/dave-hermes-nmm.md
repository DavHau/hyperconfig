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
| hermes profile `nmm` in dave-hermes with the static `nmm` skill (`dave-hermes-nmm/SKILL.md`) | same file, `dave-hermes-nmm-profile.service` | landed |
| key authorized for `agent` in asof-agents | nmm's flake | **waits: Dave adds the line below; the swarm deploys agents** |

History: a first version exported afk's skills and nmm's trunk text from
the container into a global skill dir (aa7d5309). Its security review found
a root code-execution path through the swarm's git config and a
frontmatter bypass; it was un-imported (30e2fd0c) and, per D28, dropped:
nothing is read from the container any more.

## Using it

The `nmm` skill lives only in the profile `nmm`; dave-hermes' default and
other profiles (finance, questions, ...) don't see it. Dave picks the
profile in the desktop/web app's profile picker, or on som with
`hermes -p nmm` (as dave-hermes). The profile was created with `hermes
profile create nmm` (same model as the agent, hermes' own layout, a SOUL
line naming its purpose); after that it is Dave's: only
`skills/nmm/SKILL.md` is rewritten on each switch.

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
    ssh som.d "runuser -u dave-hermes -- hermes -p nmm skills list" | grep nmm   # present
    ssh som.d "runuser -u dave-hermes -- hermes skills list" | grep -w nmm       # absent
    # after the nmm change:
    ssh som.d "runuser -u dave-hermes -- ssh asof-agents true"
