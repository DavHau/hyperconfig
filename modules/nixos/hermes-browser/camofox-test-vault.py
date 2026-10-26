"""Vault driver for camofox-test.nix (patches/hermes-camofox-vault.patch), run as alice with hermes'
own interpreter, through hermes' tool registry like the agent loop, against her real camofox-browser
and the login page of camofox-test-site.py.

  vault <site>   the vault tools read the page's origin and fill a saved password into the page's
                 password field; on another origin the fill refuses and writes nothing.

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

import model_tools  # noqa: E402,F401  (registers the tools)
import tools.browser_camofox as bc  # noqa: E402
from agent.vault_store import get_vault_store  # noqa: E402
from tools.registry import registry  # noqa: E402

PASSWORD = "vault-test-Pw-0123456789"
T = "vault-a"


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def call(name, **args):
    out = registry.dispatch(name, args, task_id=T)
    print(f"--- {name}({json.dumps(args)}) -> {out[:800]}", flush=True)
    check(PASSWORD not in out, f"{name} does not echo the password")
    return json.loads(out)


def password_length():
    return call("browser_console", expression="document.getElementById('pw').value.length").get("result")


def vault(site):
    check(call("browser_navigate", url=site + "/login").get("success") is True, "the login page loads")
    out = call("browser_vault_save_login", label="test")
    check(out.get("error_type") == "prompt_unavailable" and site in out.get("error", ""),
          "save_login reads the page's origin (headless: asks for no login)")

    meta = get_vault_store().add_item("login", "test", {"identifier_type": "username", "identifier": "alice",
                                                        "password": PASSWORD}, origin=site)
    out = call("browser_vault_fill", handle=meta.id)
    check(out.get("success") is True and out.get("filled_fields") == 1 and out.get("origin") == site,
          "browser_vault_fill fills one field on the bound origin")
    check(password_length() == len(PASSWORD), "the password field holds the saved password")

    other = site.replace("127.0.0.1", "localhost")
    check(call("browser_navigate", url=other + "/login").get("success") is True, "the same page on another origin loads")
    out = call("browser_vault_fill", handle=meta.id)
    check(out.get("error_type") == "origin_mismatch", "the fill refuses another origin")
    check(password_length() == 0, "and writes nothing")

    bc.requests.delete(f"{bc.get_camofox_url()}/sessions/{bc._get_session(T)['user_id']}",
                       headers=bc._auth_headers(), timeout=30)


if __name__ == "__main__":
    vault(sys.argv[2])
    print("ALL PASSED", flush=True)
