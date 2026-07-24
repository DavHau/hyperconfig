# Minimal Local Fabro + omp ACP Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run fabro workflows locally on the Anthropic subscription via `omp acp`, no GitHub, and pilot a gateless spec→plan→implement→verify→done pipeline on a copy of VibePN.

**Architecture:** fabro (already packaged, on-demand server, local sandbox) drives omp as the sole agent through ACP stdio nodes; no LLM provider is ever registered in fabro. VibePN work happens in a full directory copy (`~/tmp/vibepn-fabro`) to isolate fabro's git checkpointing from the jj-colocated original.

**Tech Stack:** fabro 0.254.0 (DOT workflows, local sandbox), omp (`omp acp --yolo`, existing Anthropic subscription OAuth), git, bash, jq, cargo-nextest/clippy (VibePN's gates).

Spec: `docs/superpowers/specs/2026-07-24-fabro-local-acp-design.md`

## Global Constraints

- NEVER register an LLM provider or API key in fabro (`fabro provider login`, `fabro secret set *_API_KEY` are all forbidden). Skip every provider step in wizards.
- NEVER export `ANTHROPIC_API_KEY` in any shell that starts `fabro server` or runs workflows.
- All agent nodes: `backend="acp"`, `acp.command="omp acp --yolo"`. No `model`, `provider`, `reasoning_effort`, `max_tokens`, or `output_schema` attributes on ACP nodes (rejected by fabro).
- Local sandbox only. Ignore checkpoint-push warnings (no usable origin).
- fabro runs against `~/tmp/vibepn-fabro` (the copy), never against `~/synced/projects/VibePN` directly.
- CLI flag check: fabro's sandbox flag has been both `--sandbox local` and `--environment local` across versions. Run `fabro run --help` once in Task 1 Step 5 and use whichever exists; use the same flag everywhere after.

## Dependency Map

- Task 1 (scratch validation): no dependencies
- Task 2 (VibePN copy): no dependencies
- Task 3 (spec-to-done workflow): depends on 2 (files land in the copy)
- Task 4 (pilot run + acceptance): depends on 1, 3

Waves:
1. Tasks 1, 2
2. Task 3
3. Task 4

---

### Task 1: Phase 1 scratch validation

**Files:**
- Create: `~/tmp/fabro-scratch/.fabro/workflows/smoke/workflow.fabro`

**Interfaces:**
- Consumes: nothing
- Produces: validated fabro↔omp ACP wiring; the confirmed sandbox CLI flag (`--sandbox local` or `--environment local`) used by Task 4

**Depends on:** none

- [ ] **Step 1: Create the scratch repo**

Run:
```bash
mkdir -p ~/tmp/fabro-scratch && cd ~/tmp/fabro-scratch
git init -b main
git commit --allow-empty -m init
```
Expected: empty git repo on `main`.

- [ ] **Step 2: Verify omp ACP responds and is subscription-authed**

Run:
```bash
command -v omp && command -v fabro
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' | timeout 30 omp acp
```
Expected: both binaries found; a JSON-RPC `result` line (any successful `initialize` response). If omp instead reports missing auth, STOP — omp login must be fixed by the operator first; do not work around with an API key.

- [ ] **Step 3: Headless fabro setup, skipping all providers**

Run (in `~/tmp/fabro-scratch`):
```bash
fabro install
fabro repo init
```
Expected: install wizard completes with NO provider/API-key configured (decline/skip every LLM provider question; LLM setup is optional in this fabro version); `fabro repo init` creates `.fabro/`.

- [ ] **Step 4: Write the smoke workflow**

Create `~/tmp/fabro-scratch/.fabro/workflows/smoke/workflow.fabro`:
```dot
digraph Smoke {
    graph [goal="Prove fabro drives omp via ACP on the subscription"]

    start [shape=Mdiamond, label="Start"]
    exit  [shape=Msquare, label="Exit"]

    hello [label="Hello", backend="acp", acp.command="omp acp --yolo", timeout="600s",
           prompt="Create a file named hello.txt in the workspace root containing exactly this line: hello from omp via acp"]
    check [label="Check", shape=parallelogram,
           script="grep -qx 'hello from omp via acp' hello.txt"]

    start -> hello -> check -> exit
}
```

- [ ] **Step 5: Validate, then run**

Run:
```bash
fabro validate .fabro/workflows/smoke/workflow.fabro
fabro run --help   # note the local-sandbox flag name; record it for Task 4
fabro run smoke --sandbox local --auto-approve   # or --environment local per previous line
```
Expected: validation passes; run reaches SUCCEEDED; `hello.txt` exists with the exact content (the `check` stage enforces this — a failed check fails the run).

- [ ] **Step 6: Verify billing criteria (operator-assisted)**

Run: inspect the run in the fabro web UI (`fabro server start` prints the URL) → run view → billing; confirm zero fabro-side tokens. Ask the operator to confirm: (a) Anthropic Console shows no new API spend, (b) subscription usage moved (omp side).
Expected: all four spec Phase-1 criteria hold (SUCCEEDED + artifact, zero fabro tokens, zero Console spend, no blocking permission prompt during the run). Do NOT proceed to Task 4 until confirmed.

### Task 2: VibePN working copy

**Files:**
- Create: `~/tmp/vibepn-fabro/` (full copy)

**Interfaces:**
- Consumes: nothing
- Produces: `~/tmp/vibepn-fabro` — plain working copy fabro may commit into; original repo wired to pull results back

**Depends on:** none

- [ ] **Step 1: Copy the repo**

Run:
```bash
cp -a ~/synced/projects/VibePN ~/tmp/vibepn-fabro
rm -rf ~/tmp/vibepn-fabro/.direnv ~/tmp/vibepn-fabro/result
cd ~/tmp/vibepn-fabro && git status --short | head -20
```
Expected: copy exists; `git status` works (copy carries `.git`, `.jj`, `.omp/`, working tree).

- [ ] **Step 2: Wire the pull-back path**

Run:
```bash
cd ~/synced/projects/VibePN
git remote add fabro-copy ~/tmp/vibepn-fabro 2>/dev/null || git remote set-url fabro-copy ~/tmp/vibepn-fabro
git remote -v | grep fabro-copy
```
Expected: original repo has remote `fabro-copy` pointing at the copy (used after the pilot to fetch result branches).

- [ ] **Step 3: Confirm build baseline in the copy**

Run (in `~/tmp/vibepn-fabro`):
```bash
nix develop --command cargo nextest run 2>&1 | tail -5
```
Expected: test suite passes at baseline (otherwise the verify stage would blame the agent for pre-existing failures). If the dev shell is unavailable, run plain `cargo nextest run` and record which invocation worked — the verify script in Task 3 Step 2 must use the same one.

### Task 3: spec-to-done workflow in the copy

**Files:**
- Create: `~/tmp/vibepn-fabro/.fabro/workflows/spec-to-done/workflow.fabro`
- Create: `~/tmp/vibepn-fabro/.fabro/workflows/spec-to-done/workflow.toml`
- Create: `~/tmp/vibepn-fabro/.fabro/workflows/spec-to-done/prompts/plan.md`
- Create: `~/tmp/vibepn-fabro/.fabro/workflows/spec-to-done/prompts/implement.md`
- Create: `~/tmp/vibepn-fabro/scripts/fabro-finalize.sh`

**Interfaces:**
- Consumes: the copy from Task 2
- Produces: runnable workflow `spec-to-done` taking inputs `spec` and `backlog`; handoff contract `.fabro-task.json` = `{"backlog": <path>, "spec": <path>, "plan": <path>}` written by the plan stage, read by implement and finalize

**Depends on:** 2

- [ ] **Step 1: fabro repo init in the copy**

Run (in `~/tmp/vibepn-fabro`):
```bash
fabro repo init
mkdir -p .fabro/workflows/spec-to-done/prompts scripts backlog/done docs/superpowers/specs/done docs/superpowers/plans/done
```
Expected: `.fabro/` initialized; `done/` folders exist.

- [ ] **Step 2: Write the workflow graph**

Create `.fabro/workflows/spec-to-done/workflow.fabro`:
```dot
digraph SpecToDone {
    graph [
        goal="Implement the spec {{ inputs.spec }} end to end, verify with the test suite, then archive backlog/spec/plan to done/",
        stall_timeout="7200s"
    ]
    rankdir=LR

    start [shape=Mdiamond, label="Start"]
    exit  [shape=Msquare, label="Exit"]

    plan      [label="Plan", backend="acp", acp.command="omp acp --yolo",
               timeout="1800s", prompt="@prompts/plan.md"]
    implement [label="Implement", backend="acp", acp.command="omp acp --yolo",
               timeout="5400s", max_visits=3, prompt="@prompts/implement.md"]
    verify    [label="Verify", shape=parallelogram, timeout="1800s", max_visits=3,
               script="cargo nextest run 2>&1 && cargo clippy --workspace --all-targets -- -D warnings 2>&1"]
    finalize  [label="Finalize", shape=parallelogram, script="bash scripts/fabro-finalize.sh"]

    start -> plan -> implement -> verify
    verify -> finalize  [label="Pass", condition="outcome=succeeded"]
    verify -> implement [label="Fix"]
    finalize -> exit
}
```
Note: if Task 2 Step 3 needed `nix develop --command`, prefix both cargo commands in `script` accordingly.

- [ ] **Step 3: Write the run config**

Create `.fabro/workflows/spec-to-done/workflow.toml`:
```toml
_version = 1

[workflow]
graph = "workflow.fabro"

[run.inputs]
spec = ""
backlog = ""
```

- [ ] **Step 4: Write the plan prompt**

Create `.fabro/workflows/spec-to-done/prompts/plan.md`:
```markdown
Read the spec at {{ inputs.spec }}, the backlog item at {{ inputs.backlog }}, and AGENTS.md.

Use the writing-plans skill to produce a detailed implementation plan for the spec. Save it as docs/superpowers/plans/<YYYY-MM-DD>-<topic>.md, where <YYYY-MM-DD> is today's date and <topic> is the spec's topic slug (the spec filename without date prefix and -design suffix).

Then write a file .fabro-task.json in the repository root containing exactly one JSON object:
{"backlog": "{{ inputs.backlog }}", "spec": "{{ inputs.spec }}", "plan": "<the plan path you just created>"}

Do not implement anything. Do not run the test suite. Do not commit.
```

- [ ] **Step 5: Write the implement prompt**

Create `.fabro/workflows/spec-to-done/prompts/implement.md`:
```markdown
Read .fabro-task.json in the repository root; it names the plan file, spec, and backlog item.

Execute the plan task by task following the executing-plans skill discipline. Consult the spec at {{ inputs.spec }} whenever the plan is ambiguous. Commit your work as you complete plan tasks.

If a previous Verify stage failed, its test/clippy output appears in the context above — fix those failures first before continuing the plan.

Rules:
- Run only targeted tests while working; a later Verify stage runs the full suite.
- Do not move any files into done/ folders; a later stage does that.
- Do not modify .fabro-task.json.
```

- [ ] **Step 6: Write the finalize script**

Create `scripts/fabro-finalize.sh` (and `chmod +x` it):
```bash
#!/usr/bin/env bash
set -euo pipefail

meta=".fabro-task.json"
[ -f "$meta" ] || { echo "missing $meta"; exit 1; }
command -v jq >/dev/null || { echo "jq not available"; exit 1; }

backlog=$(jq -r .backlog "$meta")
spec=$(jq -r .spec "$meta")
plan=$(jq -r .plan "$meta")
for f in "$backlog" "$spec" "$plan"; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

mkdir -p backlog/done docs/superpowers/specs/done docs/superpowers/plans/done
git mv "$backlog" backlog/done/
git mv "$spec" docs/superpowers/specs/done/
git mv "$plan" docs/superpowers/plans/done/
rm -f "$meta"
git add -A backlog docs/superpowers .fabro-task.json
git commit -m "chore: complete $(basename "$backlog" .md) — archive backlog/spec/plan to done"
echo "finalized: $backlog $spec $plan"
```

- [ ] **Step 7: Validate the workflow**

Run (in `~/tmp/vibepn-fabro`):
```bash
fabro validate .fabro/workflows/spec-to-done/workflow.fabro
```
Expected: PASS (undefined-input warnings for `spec`/`backlog` are acceptable at validate time). If validation rejects routing a failed command outcome via the `Fix` edge, apply this exact fallback and re-validate: change the `verify` script to
`(cargo nextest run 2>&1 && cargo clippy --workspace --all-targets -- -D warnings 2>&1) && echo '{"outcome":"succeeded"}' || echo '{"outcome":"failed"}'`
and add `output_schema="routing"` to the `verify` node (command nodes support it; the script then always exits 0 and routing comes from the JSON).

### Task 4: Pilot run and acceptance

**Files:**
- Modify: `~/tmp/vibepn-fabro` (agent-driven changes, result branches)

**Interfaces:**
- Consumes: validated wiring + flag name (Task 1), workflow `spec-to-done` and `.fabro-task.json` contract (Task 3)
- Produces: spec acceptance criterion 2 — one backlog item spec→done with zero API spend

**Depends on:** 1, 3

- [ ] **Step 1: Pick the pilot item and confirm its spec exists**

Run (in `~/tmp/vibepn-fabro`):
```bash
ls backlog/*.md docs/superpowers/specs/*.md
```
Expected: choose the smallest backlog item that already has a matching spec written by the operator (per the design, brainstorming→spec is the human step and happens in a live omp session first). If no spec exists yet for any backlog item, STOP and hand back to the operator to brainstorm one (suggest `backlog/config-range.md`, the smallest item).

- [ ] **Step 2: Run the pipeline**

Run (in `~/tmp/vibepn-fabro`, flag per Task 1 Step 5):
```bash
fabro run spec-to-done \
  -I spec=docs/superpowers/specs/<chosen>-design.md \
  -I backlog=backlog/<chosen>.md \
  --sandbox local --auto-approve
```
Expected: stages Plan → Implement → Verify (→ Fix loop ≤ 2 re-entries) → Finalize all green; run SUCCEEDED. On a FAILED run after 3 implement visits: report honestly, leave files in place (that is the designed retry signal), and inspect `fabro logs` — do not hand-finish the item.

- [ ] **Step 3: Verify the archive moves**

Run:
```bash
cd ~/tmp/vibepn-fabro
ls backlog/done/ docs/superpowers/specs/done/ docs/superpowers/plans/done/
git log --oneline -3
test ! -f .fabro-task.json && echo meta-cleaned
```
Expected: the three files moved to their `done/` folders in the finalize commit; `.fabro-task.json` gone.

- [ ] **Step 4: Billing acceptance (operator-assisted)**

Run: fabro web UI run billing view; ask operator to re-check Anthropic Console.
Expected: zero fabro-side tokens, zero API spend for the entire pilot run.

- [ ] **Step 5: Pull results back into the real repo (operator decision)**

Run (in `~/synced/projects/VibePN`):
```bash
git fetch fabro-copy
git branch -r --list 'fabro-copy/*'
```
Expected: result branches visible from the original repo. Present the diff to the operator (`git diff main...fabro-copy/main` or the relevant branch); merging back is the operator's call, not part of this plan.

- [ ] **Step 6: Record the outcome**

Update `docs/superpowers/specs/2026-07-24-fabro-local-acp-design.md` (hyperconfig) Status line to `piloted` on success, and note any deviations discovered (flag names, routing fallback used, nix-develop wrapping) in a short "Pilot notes" section appended to the spec. Commit in hyperconfig via jj.
Expected: spec reflects reality for the next iteration (workflow upstreaming into real VibePN, NixOS service, etc.).
