# searxng-readcheck PART...: does the review's file tool show each part
# exactly as it is? Run by ./searxng-diff.sh with the python of the
# hermes the infra-space agent runs (./searxng-diff.nix: its hermesVenv,
# from the system's own config, never a PATH lookup), so this is that
# hermes' own read path, not a copy of it: a hermes update that adds a
# transformation is checked by the next run without a change here.
#
# Per part, in-process, a fresh task each: model_tools.handle_function_call
# ("read_file", {"path": <part>}) with the reviewer's defaults (no offset,
# no limit), i.e. the registry's handler read_file_tool (pagination,
# binary detection, the char budget, the per-line clamp, BOM strip,
# _strip_terminal_fence_leaks, redact_sensitive_text(file_read=True), ...)
# plus the request middleware and transform_tool_result hooks; then
# tool_result_storage.maybe_persist_tool_result (the executor's spill)
# and tool_dispatch_helpers.make_tool_result_message (its wrapping), as
# agent/tool_executor.py applies them before the result enters context.
# The text the reviewer would see must be the part's bytes, decoded as
# UTF-8, with only the `<n>|` line-number gutter added (1, 2, ... without
# a gap), and the read whole (no truncation, no error, not binary).
#
# Then the result goes through tool_result_storage.enforce_turn_budget
# as a batch of its own (one read in the turn, the budget hermes uses
# when the context length is unknown, budget_for_context_window(None),
# the largest it gives): a part that spills there alone holds. That is
# why the reviewer reads exactly one part per turn (SKILL.md 2b):
# several reads in one turn share that budget and the largest would
# spill. Assumed, not checked here: context compression and the
# proactive tool-result prune summarize OLD tool results only, after
# the turn that read them (the reviewer has seen each part whole by
# then); the reviewer rejects on `<persisted-output>` or a pruned stub
# anyway. hermes' vault-value redaction (exact values a browser_vault
# fill registered) is empty in this fresh process; the reviewer's
# subagent runs no browser, so it is empty there too.
#
# Config: the agent's own limits and policies (tool_output.max_line_length,
# file_read_max_chars, security.redact_secrets) live in its config.yaml;
# a copy of $HERMES_HOME/config.yaml (when readable) goes into a scratch
# HERMES_HOME, $HERMES_MANAGED_DIR passes through. Nothing else of the
# agent's home is used or written; the scratch home is removed at the
# end. Importing hermes may spawn child processes of its own (its
# hourly scratch prune runs detached, on the scratch home); they touch
# nothing of the agent's.
#
# stdout: one `HOLD <reason>` line per part the reviewer would see
# changed; exit 3 if any, 0 if none, anything else = the check failed
# (the caller holds then too).
import json
import os
import shutil
import sys
import tempfile


def main(parts):
    scratch = tempfile.mkdtemp(prefix="searxng-readcheck-")
    try:
        return check(scratch, parts)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def check(scratch, parts):
    home = os.path.join(scratch, "hermes")
    os.mkdir(home)
    agent_home = os.environ.get("HERMES_HOME")
    if agent_home:
        cfg = os.path.join(agent_home, "config.yaml")
        if os.access(cfg, os.R_OK):
            shutil.copyfile(cfg, os.path.join(home, "config.yaml"))
    os.environ["HERMES_HOME"] = home
    os.environ["HOME"] = scratch
    for v in ("XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
        os.environ[v] = scratch
    os.environ.pop("TERMINAL_CWD", None)

    import model_tools
    from agent.tool_dispatch_helpers import make_tool_result_message
    from tools.budget_config import budget_for_context_window
    from tools.tool_result_storage import PERSISTED_OUTPUT_TAG, enforce_turn_budget, maybe_persist_tool_result
    budget = budget_for_context_window(None)

    holds = []
    for i, part in enumerate(parts):
        path = os.path.abspath(part)
        name = os.path.basename(part)
        raw = open(path, "rb").read()
        try:
            want = raw.decode("utf-8")
        except UnicodeDecodeError as e:
            holds.append(f"{name}: not UTF-8 at byte {e.start}, read_file refuses or replaces it")
            continue
        out = model_tools.handle_function_call(
            "read_file", {"path": path}, task_id=f"searxng-readcheck-{i}")
        cid = f"call_readcheck_{i}"
        persisted = maybe_persist_tool_result(content=out, tool_name="read_file", tool_use_id=cid,
                                              config=budget)
        if persisted != out:
            holds.append(f"{name}: the tool result is spilled to a file (not read inline)")
            continue
        msg = make_tool_result_message("read_file", persisted, cid)
        if msg.get("content") != out:
            holds.append(f"{name}: the tool message rewrites or wraps the result")
            continue
        # the turn: this one read alone
        batch = [msg]
        enforce_turn_budget(batch, config=budget)
        if batch[0].get("content") != out or PERSISTED_OUTPUT_TAG in str(batch[0].get("content")):
            holds.append(f"{name}: one read of it alone is spilled by the turn budget")
            continue
        try:
            res = json.loads(out)
        except ValueError:
            holds.append(f"{name}: read_file did not return its JSON result: {ascii(out[:80])}")
            continue
        bad = [k for k in ("error", "is_binary", "is_image", "truncated", "truncated_by",
                           "truncated_lines", "next_offset") if res.get(k)]
        if bad or not isinstance(res.get("content"), str):
            holds.append(f"{name}: read_file does not show it whole ({', '.join(bad) or 'no content'})")
            continue
        got = res["content"].split("\n")
        exp = want.removesuffix("\n").split("\n")
        # the reason names the line and the kind, never the text (it goes
        # into the report and a decision; a secret stays out of both)
        for n, line in enumerate(got, 1):
            pre = f"{n}|"
            if not line.startswith(pre):
                holds.append(f"{name}: line {n}: read_file's line numbers skip or change")
                break
            body = line[len(pre):]
            if n > len(exp) or body != exp[n - 1]:
                kind = next((k for k, m in (("a secret redaction", "[REDACTED"),
                                            ("a secret redaction", "\u00abredact"),
                                            ("a cut line", "... [truncated]"))
                             if m in body and (n > len(exp) or m not in exp[n - 1])), "a change")
                holds.append(f"{name}: line {n}: read_file shows it with {kind}")
                break
        else:
            if len(got) != len(exp):
                holds.append(f"{name}: read_file shows {len(got)} lines, the part has {len(exp)}")
    for h in holds:
        print(f"HOLD the review part {h}: the reviewer would not see what the part holds")
    return 3 if holds else 0


if __name__ == "__main__":
    rc = 2
    try:
        rc = main(sys.argv[1:])
    except Exception as e:  # any failure is a hold for the caller
        print(f"searxng-readcheck: {type(e).__name__}: {e}", file=sys.stderr)
        rc = 2
    sys.stdout.flush()
    sys.stderr.flush()
    # hermes' background threads (terminal cleanup) would raise at shutdown
    os._exit(rc)
