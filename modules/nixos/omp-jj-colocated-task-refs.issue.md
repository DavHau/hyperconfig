# Upstream issue draft for can1357/oh-my-pi

(File with `gh issue create --repo can1357/oh-my-pi --title ... --body-file ...`;
the accompanying `omp-jj-colocated-task-refs.patch` is the proposed fix and
applies clean to v16.3.5.)

---

Title: Isolated-task branch merge silently destroys colocated jj repos (stack rebased onto stale bookmark)

## Summary

`task` with `isolated: true` in branch merge mode
(`task.isolation.merge: branch`) creates a real git branch
`refs/heads/omp/task/<id>` in the parent repo, cherry-picks it, and deletes
it (`packages/coding-agent/src/task/worktree.ts`: `commitToBranch`,
`mergeTaskBranches`, `cleanupTaskBranches`).

In a **colocated jj checkout** (`jj git init --colocate` — increasingly
common), that transient branch is imported by ANY concurrent `jj` invocation
(starship prompt segment, file watcher, the user running `jj st`). When the
harness then deletes the branch after a successful merge, jj's next
`import git refs` abandons the commits the branch had pinned and
auto-rebases their descendants. Because jj does not treat detached git HEAD
ancestry as pinning, the abandoned set extends down to the nearest surviving
branch — typically a `main` bookmark sitting N commits behind jj's `@`
(normal jj usage never advances git branches). Result: the parent's ENTIRE
commit stack is rebased onto the stale bookmark, every commit in between is
orphaned, files vanish from the working copy, and conflict markers appear in
files the subagent never touched — while the merge reports **success**.

Observed in production 2026-07-06: a 16-commit stack orphaned; recovery
required `jj op restore`. The `jj op log` signature is an
`import git refs` / `import git head` pair whose ref-import shows the
`omp/task/<id>` bookmark going to `(absent)`, N ancestor commits becoming
hidden, and every stack commit rewritten with `(conflict)`.

## Reproduction (no LLM needed; drives the real merge functions)

```ts
// bun repro.ts — from packages/coding-agent; jj + git on PATH
// 1. git init -b main; one commit            (main stays pinned here)
// 2. jj git init --colocate
// 3. four `jj commit` stack commits          (git HEAD = @-, main lags 4 back)
// 4. baseline = captureBaseline(repo)        (as prepareIsolationContext does)
// 5. clone repo -> iso; agent commits agent.txt there
// 6. parent runs `jj describe -r @-`         (parent keeps working; optional —
//                                             destruction happens without it too)
// 7. commitToBranch(iso, baseline, "X", ...)
// 8. `jj log`                                 <-- concurrent jj invocation
// 9. mergeTaskBranches(...); cleanupTaskBranches(...)
// 10. jj log
```

Observed (v16.3.5):

```
mergeTaskBranches: {"merged":["omp/task/ReproTask"],"failed":[]}
== jj log ==
710af849a9c8
7b4b4d7233f3 agent: add agent.txt
d7cf66967900 stack commit 4 (amended while task ran)
f40ce318f44d base — main stays pinned here          <- stack commits 1-3 GONE
== files == agent.txt base.txt stack4.txt           <- stack1-3.txt vanished
```

jj emits: `Abandoned 5 commits that are no longer reachable.` /
`Rebased 3 descendant commits off of commits rewritten from git`.

Expected: full stack intact with the agent commit cherry-picked on top —
which is exactly what happens when no `jj` command runs between branch
creation and deletion. The bug is a race with any concurrent jj invocation,
so it is intermittent in exactly the worst way.

Note the cherry-pick itself is NOT the problem — it correctly lands on the
current git HEAD. The destruction comes purely from the
create-import-delete lifecycle of the `refs/heads/omp/task/*` branch.

## Fix

Keep task refs OUT of `refs/heads/`: store them at `refs/omp/task/<id>`.
jj imports only heads/tags/remotes, so the ref is invisible to jj no matter
when it runs; git resolves the short name `omp/task/<id>` through its
`refs/<name>` lookup fallback, so cherry-pick ranges, `git show
omp/task/<id>:path` recovery, and log inspection all keep working verbatim.

Patch (applies to v16.3.5) changes:

- `src/utils/git.ts`: add `ref.update` / `ref.tryDelete` (`git update-ref`).
- `src/task/worktree.ts`:
  - `taskBranchRef()` maps `omp/task/<id>` -> `refs/omp/task/<id>`;
  - `commitToBranch` fetch target + ref creation use the hidden ref; temp
    worktrees check out detached and `advanceTaskRef()` moves the ref after
    each commit (detached worktrees no longer advance a branch implicitly);
  - `replayFilteredAgentCommits` same treatment;
  - `mergeTaskBranches` resolves the hidden ref explicitly (raw-name
    fallback for callers passing real branches);
  - `cleanupTaskBranches` deletes via `update-ref -d` with `git branch -D`
    fallback for legacy refs.
- Regression tests:
  - `test/task/worktree.test.ts`
    ("task refs stay outside refs/heads (colocated jj safety)") asserts the
    ref is absent from `refs/heads/*`, still resolvable, mergeable, and
    cleanable on all three commitToBranch paths.
  - `test/task/worktree-jj-colocated.test.ts` is a real jj+git integration
    test (skipped when `jj` is not installed, ~1s): it builds a colocated
    repo with a 4-commit jj stack above a pinned `main`, runs the actual
    captureBaseline → commitToBranch → mergeTaskBranches →
    cleanupTaskBranches pipeline with a parent amend mid-run and a
    concurrent `jj log` mid-merge, and asserts no `omp/task/*` bookmark is
    ever imported, the stack survives unrewritten and conflict-free, and
    the agent commit lands. On unpatched v16.3.5 both tests fail exactly at
    the incident's two symptoms (bookmark imported; stack commits orphaned).

With the patch, the identical repro (including the mid-merge `jj log` and
the parent amend) ends healthy:

```
== jj log ==
5be8b41b3c65 agent: add agent.txt
f14585038be0 stack commit 4 (amended while task ran)
821d918b64f1 stack commit 3
a7b83873391f stack commit 2
d336c84a73fd stack commit 1
0f1014dd7739 base — main stays pinned here
== files == agent.txt base.txt stack1.txt stack2.txt stack3.txt stack4.txt
```

`bun test test/task/` — 223 pass, 0 fail.

## Related loud failure (same root, lesser symptom)

The known "error: Entry '<file>' not uptodate. Cannot merge." merge failures
when the parent working copy changed during the run are the benign sibling
of this bug (stash/cherry-pick racing jj's index updates); the hidden-ref
change does not eliminate that race, but it removes the silent-destruction
mode entirely.
