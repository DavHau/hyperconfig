"""Parallel subagents in the browser, for the browser check (default.nix): run as alice with
hermes' own interpreter, through hermes' tool registry, against her real camofox-browser and the
stand-in residential proxy (residential-stub.py), with managed persistence on as on every agent.

  concurrency <site>   the parent session sets a cookie in the agent's shared profile; then three
                       children (threads under delegate_task's child context, each its own task_id)
                       run at once:
                         - each browses in a context of its own: its cookie is the only one it sees,
                           not the parent's, not a sibling's;
                         - each snapshots its own page and clicks the ref of its own link, landing on
                           its own next page (no cross-talk in tabs or refs);
                         - each switches to the residential proxy (country us) and gets an exit
                           session of its own, the same one on every page of that task;
                         - one child switches residential off: the others stay on their exits;
                       browser_context(shared) gives a child the parent's cookie (explicit opt-in),
                       and a child ending there leaves the profile alone; a cron run gets its own
                       context; at task end every child context is deleted with its saved state.

Exits 1 on the first failed check; every check prints a PASS/FAIL line.
"""
import importlib
import json
import os
import re
import sys
import threading

home = os.environ["HERMES_HOME"]
os.makedirs(home, exist_ok=True)
with open(os.path.join(home, "config.yaml"), "w") as f:
    f.write("browser:\n  cloud_provider: camofox\n  command_timeout: 65\n  allow_private_urls: true\n"
            "  camofox:\n    managed_persistence: true\n"
            "plugins:\n  enabled: [camofox]\n"
            "agent:\n  disabled_toolsets: [browser-use, browser-cdp]\n")
os.makedirs(os.path.join(home, "plugins"), exist_ok=True)
if not os.path.lexists(os.path.join(home, "plugins", "camofox")):
    os.symlink(os.environ["CAMOFOX_PLUGIN"], os.path.join(home, "plugins", "camofox"))
    with open(os.environ["CAMOFOX_PLUGIN_RECORD"]) as src, \
            open(os.path.join(home, "plugins", ".install-metadata.json"), "w") as dst:
        dst.write('{"camofox": ' + src.read() + '}')
os.makedirs(os.environ["TERMINAL_CWD"], exist_ok=True)

import model_tools  # noqa: E402,F401  (discovers the plugins)
from agent.delegation_context import delegated_child_context  # noqa: E402
from tools.registry import registry  # noqa: E402

client = importlib.import_module("hermes_plugins.camofox.camofox_client")
tools = importlib.import_module("hermes_plugins.camofox.camofox_tools")

failed = threading.Event()
lock = threading.Lock()


def check(cond, what):
    with lock:
        print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        failed.set()
        raise AssertionError(what)


def call(task, name, **args):
    out = registry.dispatch(name, args, task_id=task)
    with lock:
        print(f"--- {name}({json.dumps(args)}) [{task}] -> {out[:300]}", flush=True)
    return json.loads(out)


def console(task, expr):
    return call(task, "browser_console", expression=expr).get("result")


def body(task):
    return console(task, "document.body.textContent") or ""


def cookies(task):
    return sorted(c.strip() for c in (console(task, "document.cookie") or "").split(";") if c.strip())


def run_children(n, fn):
    barrier = threading.Barrier(n)
    errors = []

    def worker(i):
        try:
            with delegated_child_context(f"child-session-{i}"):
                fn(i, f"sa-{i}-conc", barrier)
        except Exception as e:  # noqa: BLE001
            errors.append((i, repr(e)))
            barrier.abort()

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=600)
    check(not errors and not failed.is_set(), f"all {n} children passed {errors}")


def concurrency(site):
    P = "parent-session"
    check(call(P, "browser_navigate", url=site + "/parent").get("success") is True, "the parent's page loads")
    console(P, "document.cookie = 'parent=1; path=/'")
    check(cookies(P) == ["parent=1"], "the parent's cookie is set in the shared profile")
    profile_uid = client.peek_session(P)["user_id"]
    check("-task-" not in profile_uid, f"the parent session uses the profile context {profile_uid}")

    seen = {}

    def child(i, task, barrier):
        check(call(task, "browser_navigate", url=f"{site}/child{i}").get("success") is True, f"child {i}: page loads")
        uid = client.peek_session(task)["user_id"]
        check(uid.startswith(profile_uid + "-task-"), f"child {i}: own context {uid}")
        console(task, f"document.cookie = 'c{i}=1; path=/'")
        barrier.wait(timeout=180)  # every child has set its cookie
        check(cookies(task) == [f"c{i}=1"], f"child {i}: sees only its own cookie, not the parent's or a sibling's")

        snap = call(task, "browser_snapshot").get("snapshot", "")
        m = re.search(re.escape(f"next /child{i}") + r'"? \[(e\d+)\]', snap)
        check(m is not None, f"child {i}: its snapshot shows its own link")
        barrier.wait(timeout=180)  # every child has its refs before anyone clicks
        call(task, "browser_click", ref="@" + m.group(1))  # type: ignore[union-attr]
        check(f"page /child{i}-next" in body(task), f"child {i}: its ref led to its own next page")

        check(call(task, "browser_residential", country="us").get("residential") is True, f"child {i}: residential on")
        check(call(task, "browser_navigate", url=f"{site}/res{i}").get("success") is True, f"child {i}: page via proxy")
        m = re.search(r"via residential (us-session-[0-9a-f]{10})", body(task))
        check(m is not None, f"child {i}: came through the proxy with a sticky session")
        with lock:
            seen[i] = m.group(1)
        barrier.wait(timeout=180)
        if i == 0:
            check(call(task, "browser_residential", country="off").get("residential") is False, "child 0: residential off")
        barrier.wait(timeout=180)  # child 0 is off again
        call(task, "browser_navigate", url=f"{site}/res{i}-again")
        text = body(task)
        if i == 0:
            check("direct" in text and "via residential" not in text, "child 0: direct again after off")
        else:
            check(f"via residential {seen[i]}" in text,
                  f"child {i}: still on its own exit after a sibling switched off")

    run_children(3, child)
    check(len(set(seen.values())) == 3, f"three children, three exit sessions {seen}")

    # The explicit opt-in: a child that needs the parent's login.
    def shared(i, task, barrier):
        check(call(task, "browser_context", context="shared").get("context") == "shared", "browser_context shared")
        call(task, "browser_navigate", url=site + "/shared")
        check("parent=1" in cookies(task), "a child in the shared context sees the parent's cookie")
        check(call(task, "browser_context", context="own").get("context") == "own", "browser_context own")
        call(task, "browser_navigate", url=site + "/own")
        check("parent=1" not in cookies(task), "back in its own context the parent's cookie is gone")
        # A child that ends while in the shared context leaves the profile alone.
        call("sa-shared-end", "browser_context", context="shared")
        call("sa-shared-end", "browser_navigate", url=site + "/shared-end")
        tools.cleanup_task("sa-shared-end")

    run_children(1, shared)
    call(P, "browser_navigate", url=site + "/parent-after")
    check(cookies(P) == ["parent=1"], "the profile context and its cookie survive every child's end")

    # A cron run (no delegated context) gets a context of its own too.
    from gateway.session_context import _VAR_MAP
    token = _VAR_MAP["HERMES_CRON_SESSION"].set("1")
    try:
        call("cron:job:1", "browser_navigate", url=site + "/cron")
        uid = client.peek_session("cron:job:1")["user_id"]
        check(uid.startswith(profile_uid + "-task-"), f"a cron run browses in its own context {uid}")
        check(cookies("cron:job:1") == [], "the cron run sees none of the parent's cookies")
        tools.cleanup_task("cron:job:1")
    finally:
        _VAR_MAP["HERMES_CRON_SESSION"].reset(token)

    # Task end: the children's contexts go, saved state included; the profile's stays.
    child_uids = []
    for i in range(3):
        s = client.peek_session(f"sa-{i}-conc")
        child_uids += [u for u in (s.get("user_id"), s.get("direct_user_id")) if u]
        tools.cleanup_task(f"sa-{i}-conc")
    for uid in child_uids:
        tabs = client.get("/tabs", params={"userId": uid}).get("tabs") or []
        check(tabs == [], f"{uid}: no tab left after task end")
    tools.cleanup_task("sa-0-conc")  # idempotent
    print("CHILD_UIDS: " + json.dumps(child_uids), flush=True)
    print("PROFILE_UID: " + profile_uid, flush=True)


if __name__ == "__main__":
    concurrency(sys.argv[2])
    print("ALL PASSED", flush=True)
