# skill-bench: does the hyperconfig-map skill make discovery cheaper?

Fixed discovery questions (`tasks.json`, from real recent work) with
regex-graded answers, each run as a fresh non-interactive hermes oneshot
on a read-only snapshot of the repo, with and without the skill.

    # from a jj workspace whose @ holds the skill version to test
    python3 tools/skill-bench/bench.py --variant A          # baseline, no skill
    python3 tools/skill-bench/bench.py --variant B2         # skill of @ preloaded
    python3 tools/skill-bench/bench.py --report             # table again
    # options: --tasks id,id  --jobs 4  --rev <git rev>  --skill on|off

Run it inside the infra-space container as `infra` (it reads the agent's
HERMES_HOME for the model config and key). Each run costs about $0.05-0.15
(12 tasks ~ $0.7-1.2).

- Bench profile: `$BENCH_DIR/home` (default `$TMPDIR/skill-bench`): a copy
  of config.yaml with skills, delegation, memory and session search off,
  and only the ANTHROPIC_* lines of .env. `.env` and `auth.json` are
  deleted when the bench ends. Runs call the inner hermes binary (the
  system `hermes` wrapper pins the agent's own HERMES_HOME).
- Snapshot: `git archive` of the revision into `$BENCH_DIR/repo-<variant>`,
  read-only, without `tools/skill-bench` (the answers). `--skill off`
  snapshots the parent of the commit that added the skill.
- With the skill: `-s hyperconfig-map` from the snapshot's `skills/`
  (skills.external_dirs of the bench profile).
- Per run: success + missing regexes, wall time, tool calls (bench
  profile's state.db), input/output/cache tokens, api calls and cost
  (`--usage-file`). Results: `$BENCH_DIR/results.jsonl`, `summary.md`,
  `runs/<variant>-<task>.answer.txt`.
- Find the token hogs of a run: its `session_id` in results.jsonl ->
  `messages` (tool_calls, tool result lengths) in `$BENCH_DIR/home/state.db`.

When the repo changes: if a graded fact moves (file renamed, value
changed), the run fails with the missing regex; fix the answer in
tasks.json. Add tasks from real subagent work that took long to find.
