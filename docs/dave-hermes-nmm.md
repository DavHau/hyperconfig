# dave-hermes drives nmm (asof-agents)

Dave's request (2026-11-21): steer the asof/nmm project from dave-hermes
instead of only through afk inside the container, with the same skills
afk sees, and keep the afk route open.

## Shape

| part | where | status |
|---|---|---|
| ssh key `dave-hermes-nmm-ssh` (clan var, owner dave-hermes) | `machines/som/dave-hermes-nmm.nix` | landed; **generate before the next som deploy** |
| `ssh asof-agents` for dave-hermes (user agent, own key, pinned host key, source som's stable `::c0de:ba5e`) | same file, ssh_config `Match` block | landed |
| afk's skills + nmm's AGENTS.md as a live skill root `/var/lib/nmm-remote-skills/skills` (timer, 5 min) | same file + `dave-hermes-nmm/export.py`, `SKILL-head.md` | landed |
| key authorized for `agent` in asof-agents | nmm's own flake (below) | **waits: nmm change, deployed by the swarm** |

Profile: dave-hermes' default profile (and every named profile, which
get the same `skills.external_dirs`). No dedicated `nmm` profile: hyperhermes
can't declare profiles, and a profile is a hermes-runtime object Dave makes
with `hermes profile create`. The `nmm` entry skill carries the project
context (nmm's AGENTS.md, the rules for working beside the swarm), so it
works from any profile. Hermes' terminal stays on som; AGENTS.md is not read
from the cwd (the repo is in the container), the skill brings it.

## What afk's sessions see (2026-11-21)

- omp 18.11.1 under `afk` (profile `afk`, `~/.omp/profiles/afk/agent`).
- Skills (`skills.customDirectories` of afk's distro config): plain `afk`
  = Superpowers library (14) + afk's own `merging-parked-task-refs`; swarm
  and `swarm open` sessions run `afk --no-superpowers` = only the latter.
  Plus omp's project walk-up `.agents/skills` in the repo:
  `analyzing-trading-runs`, `probing-model-knowledge-cutoff`,
  `test-driven-development`. No `.claude`/`.omp` skill dirs exist.
- Always-applied rules (afk wrapper links them into `rules/`): jj-basics,
  isolated-task-merge, afk-devshells, afk-unavailable-programs,
  afk-nix-store, afk-running-commands, afk-dependency-sources.
- Extensions: superpowers.ts (injects using-superpowers; no-op with
  --no-superpowers), direnv.ts, isolation-guard.ts,
  herdr-omp-agent-state.ts (swarm-omp-profile links it; pane state).
- Context: `AGENTS.md` at the repo root; swarm sessions get the role
  brief (`swarm brief`: constitution + roles/<role>/prompt.md).
- Models: `models.yml` (anthropic -> TeamClaude with client key `nmm`;
  `p0-background/qwen` via the p0 proxy); default
  `anthropic/claude-opus-5:low`, swarm launches `claude-opus-5-5`.

The export renames each to `nmm-<name>` and prefixes its description with
"Only for nmm work ..." so dave-hermes' own same-named skills
(test-driven-development, systematic-debugging, requesting-code-review) and
its other work are not taken over.

## nmm change (Dave's repo, deployed by the swarm)

In nmm `machines/agents/configuration.nix`, authorize the key for `agent`
only (not root), from som only, no forwarding:

```nix
  # dave-hermes on som (hyperconfig machines/som/dave-hermes-nmm.nix):
  # agent only, from som's stable address, no forwarding or agent.
  hermesKey = ''from="2405:9800:b901:94e3::c0de:ba5e",restrict,pty <contents of hyperconfig vars/per-machine/som/dave-hermes-nmm-ssh/key.pub/value>'';
  ...
    users.agent = {
      ...
      openssh.authorizedKeys.keys = keys ++ [ hermesKey ];
```

`machines/agents/**` is in `[second-review]` of `swarm/gates.toml`: file it
as a swarm task (or Dave commits it) and the integrator deploys agents with
`swarm deploy agents` (a switch, no container restart).

## Verify (after som deploy + the nmm change)

    ssh som.d systemctl start nmm-remote-skills && ssh som.d ls /var/lib/nmm-remote-skills/skills
    ssh som.d "runuser -u dave-hermes -- ssh asof-agents 'cd nmm && jj st'"
    # in dave-hermes: "list your nmm skills" -> nmm + nmm-* (19 on 2026-11-21)

## Trouble to expect

See the report in the task that landed this (also summarized for Dave):
shared jj op log with live sessions, owner-gate powers of an ssh login as
`agent`, TeamClaude cost of afk runs started over ssh.
