"""browser_downloads driver for the browser check (default.nix), run with hermes' own interpreter as
the agent user, through hermes' tool registry like the agent loop.

  owner <site> <sha-helper>   alice: downloads by link, form, redirecting form and
                              script; saves, refusals, a second userId's isolation.
                              Prints "IDS: <json>" with her download ids.
  other <site> <ids-file>     bob: alice's ids (a JSON list) are unknown to his own server.
  unreachable                 bob pointed at alice's port: no connection.

Exits 1 on the first failed check; every check prints a PASS/FAIL line.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

home = os.environ["HERMES_HOME"]
os.makedirs(home, exist_ok=True)
with open(os.path.join(home, "config.yaml"), "w") as f:
    # A random camofox userId per task, like the ephemeral identity; the private
    # test site lives on loopback.
    f.write("browser:\n  cloud_provider: camofox\n  command_timeout: 65\n  allow_private_urls: true\n")
os.makedirs(os.environ["TERMINAL_CWD"], exist_ok=True)

import model_tools  # noqa: E402
import tools.browser_camofox as bc  # noqa: E402
from tools.registry import registry  # noqa: E402

WS = os.environ["TERMINAL_CWD"]


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def call(task, name, **args):
    out = registry.dispatch(name, args, task_id=task)
    print(f"--- {name}({json.dumps(args)}) [{task}] -> {out[:600]}", flush=True)
    return json.loads(out)


def ref(snap, label):
    return "@" + re.search(re.escape(label) + r'"? \[(e\d+)\]', snap).group(1)


def owner(site, sha_helper):
    def sha(name):
        return subprocess.run([sys.executable, sha_helper, "--sha", name],
                              capture_output=True, text=True, check=True).stdout.strip()

    names = [t["function"]["name"] for t in
             model_tools.get_tool_definitions(enabled_toolsets=["hermes-cli"], quiet_mode=True)]
    check("browser_downloads" in names, "browser_downloads is offered in Camofox mode")

    A, B = "agent-a", "agent-b"
    snap = call(A, "browser_navigate", url=site + "/")["snapshot"]
    for label, fname in [("Direct link download", "link.bin"), ("Form download", "form.bin"),
                         ("Redirect form download", "redirect.bin"), ("JS download", "js.bin")]:
        check(call(A, "browser_click", ref=ref(snap, label)).get("success") is True, f"{label}: click succeeds")
        new = [d for d in call(A, "browser_downloads")["downloads"] if d["new"]]
        check(len(new) == 1 and new[0]["filename"] == fname and new[0]["status"] == "complete",
              f"{label}: one new complete download {fname}")
        saved = call(A, "browser_downloads", save=new[0]["id"])
        path = os.path.join(WS, fname)
        check(saved.get("path") == path, f"{label}: saved as {path}")
        want = sha(fname)
        with open(path, "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        check(saved["sha256"] == got == want, f"{label}: sha256 {want}")

    # What the agent fell back to before: fetch() re-POSTing the form. The 302 to
    # another origin carries no CORS header, so Firefox fails it.
    call(A, "browser_click", ref=ref(snap, "Fetch re-POST"))
    time.sleep(2)
    res = call(A, "browser_console", expression="document.getElementById('fetchresult').textContent")
    check("NetworkError" in str(res.get("result")), "fetch() of the redirecting POST is a NetworkError")

    check("exists" in call(A, "browser_downloads", save="latest").get("error", ""),
          "an existing file is kept without overwrite")
    check(call(A, "browser_downloads", save="latest", overwrite=True).get("success") is True,
          "overwrite=true replaces it")
    os.symlink("/tmp", os.path.join(WS, "out"))
    for bad in ["../escape.bin", "/tmp/escape.bin", "a/../../escape.bin", "out/escape.bin"]:
        r = call(A, "browser_downloads", save="latest", path=bad)
        check("outside the working directory" in r.get("error", ""), f"path {bad!r} is refused")
    check(not os.path.exists("/tmp/escape.bin") and not os.path.exists(os.path.join(WS, "..", "escape.bin")),
          "nothing was written outside the working directory")

    call(A, "browser_click", ref=ref(snap, "Big download"))
    big = [d for d in call(A, "browser_downloads")["downloads"] if d["new"]]
    check(len(big) == 1 and big[0]["size"] == 60 * 1024 * 1024, "the 60 MiB download is listed")
    r = call(A, "browser_downloads", save=big[0]["id"])
    check("over the 52428800-byte limit" in r.get("error", "") and not os.path.exists(os.path.join(WS, "big.bin")),
          "the 60 MiB download is refused")

    ids = [d["id"] for d in call(A, "browser_downloads")["downloads"]]
    # A second camofox userId on the same server: none of A's downloads.
    check("No browser session" in call(B, "browser_downloads").get("error", ""), "B without a tab: no session")
    call(B, "browser_navigate", url=site + "/")
    check(call(B, "browser_downloads")["downloads"] == [], "B lists no downloads")
    check("No download" in call(B, "browser_downloads", save=ids[0]).get("error", ""), "B cannot save A's download")
    sa, sb = bc._get_session(A), bc._get_session(B)
    raw = bc.requests.get(f"{bc.get_camofox_url()}/tabs/{sa['tab_id']}/downloads",
                          params={"userId": sb["user_id"], "includeData": "true"}, headers=bc._auth_headers())
    check(raw.status_code in (404, 410) and "dataBase64" not in raw.text,
          f"camofox refuses B's userId on A's tab (HTTP {raw.status_code})")
    print("IDS: " + json.dumps(ids), flush=True)
    print("USERS: " + json.dumps([sa["user_id"], sb["user_id"]]), flush=True)


def other(site, ids):
    snap = call("bob", "browser_navigate", url=site + "/")
    check(snap.get("success") is True, "bob browses on his own server")
    check(call("bob", "browser_downloads")["downloads"] == [], "bob lists no downloads")
    for i in ids:
        check("No download" in call("bob", "browser_downloads", save=i).get("error", ""), f"bob cannot save {i}")


def unreachable():
    r = call("bob", "browser_navigate", url="http://127.0.0.1:8765/")
    check(r.get("success") is False and "Cannot connect" in r.get("error", ""), "bob cannot reach alice's server")
    r = call("bob", "browser_downloads")
    check(r.get("success") is False, "bob cannot list through alice's server")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "owner":
        owner(sys.argv[2], sys.argv[3])
    elif mode == "other":
        with open(sys.argv[3]) as f:
            other(sys.argv[2], json.load(f))
    else:
        unreachable()
    print("ALL PASSED", flush=True)
