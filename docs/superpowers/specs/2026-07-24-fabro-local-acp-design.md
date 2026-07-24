# Minimal local fabro + omp ACP setup — Design

Date: 2026-07-24
Status: approved (brainstorm session)
Scope: hyperconfig (infra) + VibePN (pilot repo)

## Goal

Run fabro workflows locally, fully billed to the existing Anthropic
subscription via omp's login, with no GitHub dependency and no API-key
billing anywhere. Pilot: automate VibePN's superpowers SDD loop from spec
to verified implementation.

## Non-goals

- No fabro-managed LLM providers (no API keys registered — makes API
  billing structurally impossible, not just configured away).
- No GitHub: local git remotes only; checkpoint-push warnings are ignored.
- No systemd service; server is started on demand.
- No Docker/Daytona sandboxes (clone path is GitHub-only upstream, #551).
- No mid-run steering: ACP stages are non-steerable by design (fabro #307).
  Control points are the spec (human) and the verify loop (mechanical).

## Architecture

Three pieces, no new services:

| Piece | Role | State |
|---|---|---|
| fabro 0.254.0 | workflow engine, on-demand `fabro server start` | already packaged (`modules/nixos/fabro`), installed on `amy` |
| omp | sole agent via ACP: `acp.command="omp acp --yolo"` | already logged into Anthropic (subscription OAuth) |
| local git | `provider="local"` sandbox + `fabro/run/*` checkpoint branches | per-repo |

```
you ──(spec, start run)──▶ fabro server ──ACP stdio──▶ omp acp --yolo ──OAuth──▶ Anthropic
                              │
                              └── checkpoints: git branches fabro/run/*
```

omp picks up the pilot repo's `.omp/config.yml` from the ACP session cwd:
model choice, approval mode, and project skills all live there, not in
fabro. ACP nodes must not carry `model`/`reasoning_effort`/`provider`
attributes (rejected by fabro's strict backend contract).

## Phase 1 — scratch validation

Throwaway repo (e.g. `~/tmp/fabro-scratch`):

1. `git init`, one commit.
2. `fabro install` (headless wizard), skip all LLM provider setup.
3. `fabro repo init`.
4. Single-node ACP workflow: prompt "create hello.txt containing
   'hello from omp via acp'", `backend="acp"`,
   `acp.command="omp acp --yolo"`, local sandbox.

Pass criteria (all required):

- Run status SUCCEEDED and `hello.txt` exists with expected content.
- fabro's run billing (web UI run view / `GET .../billing` API) reports
  zero fabro-side tokens.
- Anthropic Console shows no API spend; usage appears on the
  subscription (omp side).
- No permission prompt ever blocks the run (`--yolo` honored
  end-to-end, including the ACP client permission gate).

Phase 2 does not start until all four hold.

## Phase 2 — VibePN spec-to-done pipeline

VibePN conventions (already in place): `backlog/*.md`,
`docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`,
`docs/superpowers/plans/YYYY-MM-DD-<topic>.md`.

Division of labor:

- **Human (interactive, outside fabro):** brainstorm a backlog item in a
  live omp session → spec file. The spec is the last human touchpoint.
- **fabro (unattended, gateless):** everything after the spec exists.

One workflow `spec-to-done` in `VibePN/.fabro/workflows/spec-to-done/`,
invoked:

```
fabro run spec-to-done \
  --var spec=docs/superpowers/specs/<file> \
  --var backlog=backlog/<item>.md
```

Graph (all agent nodes ACP/omp; no human gates):

```
start → plan → implement → verify → finalize → exit
                   ▲          │
                   └──fail────┘   (max_visits=3, then run FAILS)
```

- **plan**: reads `{{spec}}` + `AGENTS.md`; writes
  `docs/superpowers/plans/YYYY-MM-DD-<topic>.md` following the
  writing-plans skill (named in the prompt; omp discovers VibePN skills
  from cwd).
- **implement**: fresh omp session; executes the plan per
  executing-plans discipline. The plan file is the entire handoff —
  no shared session state between agents.
- **verify**: deterministic command nodes: `cargo nextest run` and
  `cargo clippy` (VibePN's existing gates). Failure loops back to
  implement with the failure output; bounded by `max_visits=3`, after
  which the run fails honestly (no silent partial success).
- **finalize** (command node, deterministic, no LLM): on green only —
  `git mv {{backlog}} backlog/done/`,
  `git mv <spec> docs/superpowers/specs/done/`,
  `git mv <plan> docs/superpowers/plans/done/`, commit.
  A failed run moves nothing; files staying in place is the retry
  signal.

## jj-colocation risk and mitigation

VibePN is jj-colocated. fabro's local sandbox commits checkpoint stages
to git branches in the working repo; concurrent jj working-copy
snapshotting against external git HEAD/branch movement is an untested
interaction.

Pilot mitigation: copy the repo to a new directory first and run fabro
only there (`cp -a ~/synced/projects/VibePN ~/tmp/vibepn-fabro`,
dropping `.direnv/`). The copy carries the working tree, `.omp/`
config, and jj state but is fully independent of the original. Results
are reviewed in the copy and pulled back via git (the original added
as a remote). Revisit (run in the real checkout directly) once the
pipeline is trusted.

## Error handling / observability

- Run inspection: fabro web UI + `fabro logs`; every stage is
  git-checkpointed, so any stage's tree is recoverable.
- ACP stage failures surface the underlying error (fixed upstream
  post-#273); first suspect for opaque failures is omp auth/approval
  state in the sandbox cwd.
- Verify-loop exhaustion fails the run; nothing is moved to `done/`.

## Policy posture

The ACP path keeps omp as the agent (own loop, own system prompt) —
the "personal use of a local agent CLI" carve-out per Anthropic's
public statements and the fabro maintainer's recommendation
(fabro #143, #313). Explicitly rejected for now: fronting fabro's
native `api` backend with subscription OAuth (technically possible via
`omp auth-broker` + `omp auth-gateway` + fabro's custom
OpenAI-compatible provider) — that is third-party-app consumption of
subscription quota, an active enforcement target, and the ban risk
lands on the personal Anthropic account.

## Future options (documented, not planned)

- `omp auth-gateway` + fabro `litellm`-style provider for steerable
  `api`-backend nodes on light stages (accepting the ToS exposure).
- Ensemble review node (second omp session cross-reviews the diff)
  before verify.
- Docker sandbox with `run.clone.enabled=false` for yolo containment.
- NixOS user service for the fabro server; shared workflow library in
  hyperconfig.
- fabro automations to trigger spec-to-done when a spec file lands.

## Acceptance criteria (pilot complete)

1. Phase 1 passes all four criteria.
2. One real VibePN backlog item goes spec → plan → implementation →
   green `cargo nextest` + `clippy` → files moved to `done/` — with no
   human input after the spec and zero Anthropic API spend.
