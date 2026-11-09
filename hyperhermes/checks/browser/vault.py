"""Vault driver for the browser check (default.nix; hermes' vault on the camofox plugin's page backend
and patches/hermes-vault-generate-password.patch), run as alice with hermes' own interpreter, through hermes' tool
registry like the agent loop, against her real camofox-browser and the login and signup pages of site.py.

  vault <site>   the vault tools read the page's origin and fill a saved password into the page's
                 password field; on another origin the fill refuses and writes nothing. create_login
                 generates a password, saves it for the signup page's origin and fills the password
                 and its confirmation, never returning it; on a page without a password field it
                 saves nothing.

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
# The agent's own Camofox plugin (the link the browser module renews in her $HERMES_HOME).
os.makedirs(os.path.join(home, "plugins"), exist_ok=True)
if not os.path.lexists(os.path.join(home, "plugins", "camofox")):
    os.symlink(os.environ["CAMOFOX_PLUGIN"], os.path.join(home, "plugins", "camofox"))
    # and its installer record, as preStart writes it
    with open(os.environ["CAMOFOX_PLUGIN_RECORD"]) as src, \
            open(os.path.join(home, "plugins", ".install-metadata.json"), "w") as dst:
        dst.write('{"camofox": ' + src.read() + '}')
os.makedirs(os.environ["TERMINAL_CWD"], exist_ok=True)

import importlib  # noqa: E402

import requests  # noqa: E402

import model_tools  # noqa: E402  (discovers the plugins)
from hermes_cli.config import load_config  # noqa: E402
from hermes_cli.tools_config import _get_platform_tools  # noqa: E402

bc = importlib.import_module("hermes_plugins.camofox.camofox_client")
from agent.vault_store import get_vault_store  # noqa: E402
from tools.registry import registry  # noqa: E402

PASSWORD = "vault-test-Pw-0123456789"
T = "vault-a"


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def call(name, **args):
    global last
    last = out = registry.dispatch(name, args, task_id=T)
    print(f"--- {name}({json.dumps(args)}) -> {out[:800]}", flush=True)
    check(PASSWORD not in out, f"{name} does not echo the password")
    return json.loads(out)


def field(expression):
    return call("browser_console", expression=expression).get("result")


def password_length():
    return field("document.getElementById('pw').value.length")


def vault(site):
    check(call("browser_navigate", url=site + "/login").get("success") is True, "the login page loads")
    # hermes 0.22 merged the vault tools into one `browser_vault` tool with an `action`.
    out = call("browser_vault", action="save_login", label="test")
    check(out.get("error_type") == "prompt_unavailable" and site in out.get("error", ""),
          "save_login reads the page's origin (headless: asks for no login)")

    meta = get_vault_store().add_item("login", "test", {"identifier_type": "username", "identifier": "alice",
                                                        "password": PASSWORD}, origin=site)
    out = call("browser_vault", action="fill", handle=meta.id)
    check(out.get("success") is True and out.get("filled_fields") == 1 and out.get("origin") == site,
          "browser_vault fill fills one field on the bound origin")
    check(password_length() == len(PASSWORD), "the password field holds the saved password")

    other = site.replace("127.0.0.1", "localhost")
    check(call("browser_navigate", url=other + "/login").get("success") is True, "the same page on another origin loads")
    out = call("browser_vault", action="fill", handle=meta.id)
    check(out.get("error_type") == "origin_mismatch", "the fill refuses another origin")
    check(password_length() == 0, "and writes nothing")

    check(call("browser_navigate", url=site + "/signup").get("success") is True, "the signup page loads")
    out = call("browser_vault", action="create_login", identifier="alice@example.com", label="signup")
    check(out.get("success") is True and out.get("filled_fields") == 2 and out.get("origin") == site
          and out.get("identifier") == "alice@example.com", "create_login fills two fields on the signup origin")
    store = get_vault_store()
    meta = store.get_meta(out.get("handle", ""))
    check(meta is not None and meta.kind == "login" and meta.origin == site and meta.identifier == "alice@example.com",
          "the vault holds the new login, bound to the signup origin and the identifier")
    generated = store.resolve_secret(meta.id)["password"]
    check(len(generated) == 24 and generated not in last, "the result carries no password")
    check(password_length() == len(generated), "the password field holds the generated password")
    check(field("document.getElementById('pw').value === document.getElementById('pw2').value") is True,
          "the confirmation holds the same password")

    saved = len(store.list_items())
    check(call("browser_navigate", url=site + "/").get("success") is True, "a page without a password field loads")
    out = call("browser_vault", action="create_login", identifier="alice@example.com")
    check(out.get("error_type") == "no_password_field" and len(store.list_items()) == saved,
          "create_login without a password field saves nothing")

    requests.delete(f"{bc.get_camofox_url()}/sessions/{bc.get_session(T)['user_id']}",
                       headers=bc._auth_headers(), timeout=30)


if __name__ == "__main__":
    vault(sys.argv[2])
    print("ALL PASSED", flush=True)
