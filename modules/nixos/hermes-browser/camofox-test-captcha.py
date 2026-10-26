"""browser_solve_captcha driver for camofox-test.nix, run as alice with hermes' own interpreter,
through hermes' tool registry like the agent loop, against her real camofox-browser and
camofox-test-captcha-site.py (the captcha page and the model stand-in).

  captcha <site>   solves the grid captcha; reports no_captcha on a plain page; a second
                   camofox userId cannot solve on the first one's tab.

Exits 1 on the first failed check; every check prints a PASS/FAIL line.
"""
import json
import os
import sys

home = os.environ["HERMES_HOME"]
os.makedirs(home, exist_ok=True)
with open(os.path.join(home, "config.yaml"), "w") as f:
    f.write("browser:\n  cloud_provider: camofox\n  command_timeout: 65\n  allow_private_urls: true\n")
os.makedirs(os.environ["TERMINAL_CWD"], exist_ok=True)

import model_tools  # noqa: E402
import tools.browser_camofox as bc  # noqa: E402
from tools.registry import registry  # noqa: E402


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def call(task, name, **args):
    out = registry.dispatch(name, args, task_id=task)
    print(f"--- {name}({json.dumps(args)}) [{task}] -> {out[:800]}", flush=True)
    return json.loads(out)


def page_text(task, element_id):
    return call(task, "browser_console", expression=f"document.getElementById('{element_id}').textContent").get("result")


def captcha(site):
    names = [t["function"]["name"] for t in
             model_tools.get_tool_definitions(enabled_toolsets=["hermes-cli"], quiet_mode=True)]
    check("browser_solve_captcha" in names, "browser_solve_captcha is offered in Camofox mode")

    A, B = "cap-a", "cap-b"
    check("browser_navigate" in call(A, "browser_solve_captcha").get("error", ""), "no tab: navigate first")
    check(call(A, "browser_navigate", url=site + "/captcha").get("success") is True, "the captcha page loads")
    out = call(A, "browser_solve_captcha")
    check(out.get("success") is True and out.get("status") == "solved", "the tool reports solved")
    check(out.get("vendor") == "prosopo" and out.get("rounds", 0) >= 1, "with the vendor and its rounds")
    check(page_text(A, "picked") == "1,5,9", "the browser clicked tiles 1, 5 and 9, then Verify")
    check(page_text(A, "result") == "Verification Success", "the page accepted the answer")

    check(call(A, "browser_navigate", url=site + "/plain").get("success") is True, "a page without a captcha loads")
    out = call(A, "browser_solve_captcha")
    check(out.get("success") is False and out.get("status") == "no_captcha", "the tool reports no_captcha")

    # A second camofox userId on the same server: A's tab is not its tab.
    call(B, "browser_navigate", url=site + "/plain")
    sa, sb = bc._get_session(A), bc._get_session(B)
    raw = bc.requests.post(f"{bc.get_camofox_url()}/tabs/{sa['tab_id']}/solve-captcha",
                           json={"userId": sb["user_id"]}, headers=bc._auth_headers(), timeout=30)
    check(raw.status_code in (404, 410), f"camofox refuses B's userId on A's tab (HTTP {raw.status_code})")

    log = bc.requests.get(site + "/log", timeout=10).json()
    check(len(log) >= 1 and not any(e.get("refused") for e in log),
          f"every model request carried an image, the model name and no tools ({len(log)} requests)")
    for session in (sa, sb):
        bc.requests.delete(f"{bc.get_camofox_url()}/sessions/{session['user_id']}", headers=bc._auth_headers(),
                           timeout=30)


if __name__ == "__main__":
    captcha(sys.argv[2])
    print("ALL PASSED", flush=True)
