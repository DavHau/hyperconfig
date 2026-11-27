"""The agent-action tools (pkgs/hermes-camofox-plugin/action-feedback.patch, pkgs/camofox-browser/
agent-actions.patch) for the browser check (default.nix): run as alice with hermes' own interpreter,
through hermes' tool registry like the agent loop, against her real camofox-browser and site.py's
/actions page.

  actions <site>
      - browser_click with text clicks a control that has no ref (a div with a click handler), and
        its result carries what changed (changes_kind diff, the new text), no snapshot needed;
      - text shown by several elements is refused with the list of matches; nth picks one;
        text shown by none says so;
      - browser_snapshot wait_for waits server-side for a text that shows 1.5 s after a click;
      - browser_type without ref types into the focused element in one call;
      - browser_console: a script error says what it was; a navigation during the expression is
        explained (navigation_race), not 'Internal server error';
      - a stale ref's error is the server's explanation without the HTTP library's noise;
      - a click that navigates returns the new page (changes_kind page).

Exits 1 on the first failed check; every check prints a PASS/FAIL line.
"""
import json
import os
import re
import sys

home = os.environ["HERMES_HOME"]
os.makedirs(home, exist_ok=True)
with open(os.path.join(home, "config.yaml"), "w") as f:
    f.write("browser:\n  cloud_provider: camofox\n  command_timeout: 65\n  allow_private_urls: true\n"
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
from tools.registry import registry  # noqa: E402

T = "actions"


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def call(name, **args):
    out = registry.dispatch(name, args, task_id=T)
    print(f"--- {name}({json.dumps(args)}) -> {out[:900]}", flush=True)
    return json.loads(out)


def ref_of(snapshot, role, name):
    m = re.search(rf'- {role} "{re.escape(name)}"[^\n]*\[(e\d+)\]', snapshot)
    return m.group(1) if m else None


def actions(site):
    nav = call("browser_navigate", url=site + "/actions")
    check(nav.get("success") is True and "Second tab" in nav.get("snapshot", ""), "the actions page loads")

    r = call("browser_click", text="Second tab")
    check(r.get("success") is True, "a control without a ref is clicked by its text")
    check(r.get("changes_kind") == "diff" and "Panel two open" in r.get("changes", ""),
          "the click's result carries what changed (a diff with the new text)")
    check("Panel one open" in r.get("changes", "") and len(r["changes"]) < len(nav["snapshot"]),
          "the diff is smaller than the page and shows the replaced line")

    r = call("browser_click", text="Select", exact=True)
    check(r.get("success") is False and "2 visible elements" in r.get("error", "") and "nth 1" in r.get("error", ""),
          "text shown by two elements is refused with the list of matches")
    r = call("browser_click", text="Select", exact=True, nth=-1)
    check(r.get("success") is True and "picked evening" in r.get("changes", ""), "nth -1 clicks the last match")
    r = call("browser_click", text="No such control")
    check(r.get("success") is False and "No visible element" in r.get("error", "")
          and "Client Error" not in r.get("error", ""), "text shown by none says so, without HTTP noise")

    snap = call("browser_snapshot")["snapshot"]
    confirm = ref_of(snap, "button", "Confirm change")
    check(confirm is not None, "the snapshot has the Confirm change button")
    r = call("browser_click", ref="@" + confirm)
    check(r.get("success") is True and "changes" in r, "a ref click carries changes too")
    r = call("browser_snapshot", wait_for="Change confirmed", timeout=10)
    check(r.get("found") is True and "Change confirmed" in r.get("snapshot", ""),
          "wait_for waits until the late text shows, then snapshots")
    r = call("browser_snapshot", wait_for="Never shown", timeout=1)
    check(r.get("success") is True and r.get("found") is False and r.get("waited_s", 0) >= 0.9,
          "wait_for gives up after its timeout with found false")

    code = ref_of(r["snapshot"], "textbox", "Code")
    check(code is not None, "the snapshot has the code box")
    check(call("browser_click", ref="@" + code).get("success") is True, "the code box is focused by a click")
    r = call("browser_type", text="482915")
    check(r.get("success") is True and r.get("element") == "(focused)", "browser_type without ref types into focus")
    v = call("browser_console", expression="document.getElementById('code').value")
    # the plugin parses a JSON-looking string result: "482915" comes back as a number
    check(str(v.get("result")) == "482915", "the focused box got the whole code in one call")

    r = call("browser_console", expression="null.x")
    check(r.get("success") is False and "JavaScript error in the expression" in r.get("error", ""),
          "a script error says what it was")
    r = call("browser_console", expression="new Promise(r => { setTimeout(() => { location.href = '/actions-done'; }, 50); setTimeout(r, 3000); })")
    check(r.get("success") is False and "navigated" in r.get("error", "") and "Internal server error" not in r.get("error", ""),
          "a navigation during the expression is explained")
    nav = call("browser_navigate", url=site + "/actions")
    check(nav.get("success") is True, "back on the actions page")

    r = call("browser_click", ref="@e999")
    check(r.get("success") is False and "Unknown ref" in r.get("error", "") and "for url" not in r.get("error", ""),
          "a stale ref's error is the server's explanation, without the HTTP library's noise")

    r = call("browser_click", text="Continue", exact=True)
    check(r.get("success") is True and r.get("changes_kind") == "page" and "All done" in r.get("changes", ""),
          "a click that navigates returns the new page")
    r = call("browser_press", key="Escape")
    check(r.get("success") is True and r.get("changes") == "(unchanged)", "a named key reports it changed nothing")
    r = call("browser_press", key="a")
    check(r.get("success") is True and "changes" not in r, "a single character stays a bare press")


if __name__ == "__main__":
    actions(sys.argv[2])
    print("ALL PASSED", flush=True)
