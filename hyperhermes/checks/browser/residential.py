"""browser_residential driver for the browser check (default.nix), run as alice with hermes' own
interpreter, through hermes' tool registry, against her real camofox-browser and a stand-in
residential proxy (residential-proxy-stub, default.nix) that logs each request's proxy username
and answers every page through it with "via residential <cc>".

  residential <site>   the tool is offered; by default the browser goes direct; after
                       browser_residential(us) a fresh context goes through the proxy as `us`;
                       'off' switches back; a bad country is refused.

Exits 1 on the first failed check; every check prints a PASS/FAIL line.
"""
import json
import os
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

import model_tools  # noqa: E402  (discovers the plugins)
from hermes_cli.config import load_config  # noqa: E402
from hermes_cli.tools_config import _get_platform_tools  # noqa: E402
from tools.registry import registry  # noqa: E402


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def call(task, name, **args):
    out = registry.dispatch(name, args, task_id=task)
    print(f"--- {name}({json.dumps(args)}) [{task}] -> {out[:600]}", flush=True)
    return json.loads(out)


def body(task):
    return call(task, "browser_console", expression="document.body.textContent").get("result") or ""


def residential(site):
    cfg = load_config()
    names = [t["function"]["name"] for t in model_tools.get_tool_definitions(
        enabled_toolsets=sorted(_get_platform_tools(cfg, "cli")),
        disabled_toolsets=cfg["agent"]["disabled_toolsets"], quiet_mode=True,
        skip_tool_search_assembly=True)]
    check("browser_residential" in names, "browser_residential is offered with RESIDENTIAL_PROXY_URL set")

    T = "res-a"
    check(call(T, "browser_navigate", url=site + "/plain").get("success") is True, "a page loads directly")
    check("via residential" not in body(T), "by default the browser does not use the proxy")

    check(call(T, "browser_residential", country="us").get("residential") is True, "switching to US")
    check(call(T, "browser_navigate", url=site + "/plain").get("success") is True, "the page loads via the proxy")
    check("via residential us" in body(T), "the page came through the proxy with country us")

    check(call(T, "browser_residential", country="usa").get("success") is False, "a bad country is refused")

    check(call(T, "browser_residential", country="off").get("residential") is False, "switching off")
    check(call(T, "browser_navigate", url=site + "/plain").get("success") is True, "the page loads again")
    check("via residential" not in body(T), "after 'off' the browser is direct again")


if __name__ == "__main__":
    residential(sys.argv[2])
    print("ALL PASSED", flush=True)
