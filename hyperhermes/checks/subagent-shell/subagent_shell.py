"""Offline check of ../../modules/core/patches/hermes-subagent-own-shell.patch, through hermes'
own terminal tool on the local backend (no LLM, no network).

  - the parent session exports a variable; three delegate_task children (delegated_child_context,
    own task ids, run at once) each see it (their shell starts from the parent's snapshot);
  - each child exports its own value and then reads it back after its siblings ran commands in
    between: every child reads its own value (before the patch the last writer of the one shared
    snapshot won);
  - a child's `unset` and `export` never reach the parent or a sibling;
  - the parent's own exports keep working after the children ran;
  - a background job a child starts survives the release of the child's shell;
  - release_child_env drops the children's environments, the parent's stays.
Exits 1 on the first failed check.
"""
import json
import os
import sys
import threading

from agent.delegation_context import delegated_child_context
from tools import terminal_tool as tt
from tools.terminal_tool import terminal_tool


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def run(task, cmd):
    out = json.loads(terminal_tool(command=cmd, task_id=task))
    return (out.get("output") or "").strip()


P = "parent-task"
run(P, "export SHARED_MARK=from-parent")
check(run(P, "echo $SHARED_MARK") == "from-parent", "the parent's export persists in its shell")

errors = []
barrier = threading.Barrier(3)


def child(i):
    task = f"sa-{i}-shell"
    try:
        with delegated_child_context(f"child-{i}"):
            if run(task, "echo $SHARED_MARK") != "from-parent":
                errors.append(f"child {i}: does not start from the parent's shell")
            run(task, f"export CHILD_MARK=child-{i}; unset SHARED_MARK")
            barrier.wait(timeout=60)
            for _ in range(3):  # siblings' commands end in between
                run(task, "true")
            barrier.wait(timeout=60)
            got = run(task, "echo ${CHILD_MARK:-none}/${SHARED_MARK:-unset}")
            if got != f"child-{i}/unset":
                errors.append(f"child {i}: read {got!r}, expected its own state")
    except Exception as e:  # noqa: BLE001
        errors.append(f"child {i}: {e!r}")


threads = [threading.Thread(target=child, args=(i,)) for i in range(3)]
for t in threads:
    t.start()
for t in threads:
    t.join(timeout=300)
check(not errors, f"each child keeps its own shell state {errors}")
check(run(P, "echo ${CHILD_MARK:-none}/${SHARED_MARK:-unset}") == "none/from-parent",
      "no child's export or unset reached the parent")
run(P, "export AFTER=1")
check(run(P, "echo $AFTER") == "1", "the parent's shell still persists exports")

with delegated_child_context("child-bg"):
    bg = json.loads(terminal_tool(command="sleep 3; echo bg-done", task_id="sa-bg-shell", background=True))
check(bool(bg.get("session_id")), f"a child starts a background job {bg}")
tt.release_child_env("sa-bg-shell")
from tools.process_registry import process_registry  # noqa: E402
import time  # noqa: E402
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    s = process_registry.get(bg["session_id"])
    if s is not None and s.exited:
        break
    time.sleep(0.2)
s = process_registry.get(bg["session_id"])
check(s is not None and s.exited and "bg-done" in (s.output_buffer or ""),
      "the child's background job ran to its end after the child's shell was released")

child_keys = [k for k in tt._active_environments if tt._CHILD_ENV_MARK in k]
check(len(child_keys) == 3, f"three child environments {child_keys}")
for i in range(3):
    tt.release_child_env(f"sa-{i}-shell")
check(not [k for k in tt._active_environments if tt._CHILD_ENV_MARK in k], "children's environments released")
check(any(tt._CHILD_ENV_MARK not in k for k in tt._active_environments), "the parent's environment stays")
print("ALL PASSED", flush=True)
os._exit(0)
