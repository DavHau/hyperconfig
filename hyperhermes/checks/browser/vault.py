"""Vault driver for the browser check (default.nix; hermes' vault on the camofox plugin's page backend
and patches/hermes-vault-generate-password.patch), run as alice with hermes' own interpreter, through hermes' tool
registry like the agent loop, against her real camofox-browser and the login and signup pages of site.py.

  vault <site>   the vault tools read the page's origin and fill a saved password into the page's
                 password field; on another origin the fill refuses and writes nothing. create_login
                 generates a password, saves it for the signup page's origin and fills the password
                 and its confirmation, never returning it; on a page without a password field it
                 saves nothing.

  card <site> <processor>
                 hosted card-field fill (hermes-vault-payment-iframe-*.patch, the plugin's
                 vault-frames.patch, camofox-browser's vault-frames plugin): a TEST card saved for the
                 shop's origin is filled into the card frame the checkout embeds directly from the
                 processor origin (made a known processor here; the real list holds Stripe, Adyen,
                 Braintree, Square), never into the same frame served from an origin the shop controls,
                 nor into the processor frame nested inside such a frame. Consent is answered yes by a
                 stand-in (headless has no prompt) and counted: a refused checkout never asks.

  hostile <site> <processor>
                 the vault's scripts never run where page code can reach them (Camoufox evaluates in an
                 Xray sandbox; the vault-frames plugin asserts it): on a login page and in a processor
                 card frame whose code hooks every built-in a fill script could call and walks fn.caller
                 from each hook (site.py /login-hostile, /checkout-hostile), the fill succeeds and no hook
                 sees the password or the card; the page's world is not the one the vault evaluates in;
                 and when the checkout navigates the card frame to a hostile page right after the vault's
                 value-free check (the navigation race), the write is refused and that page gets nothing.

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
# A test card number (Stripe's), never a real one.
CARD = {"card_number": "4242424242424242", "cardholder_name": "Test User", "exp_month": "12", "exp_year": "2034",
        "cvc": "123", "billing_postal_code": "10115"}
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
    check(CARD["card_number"] not in out, f"{name} does not echo the card number")
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


def card(site, processor):
    import time
    from unittest.mock import patch

    from agent.browser_page_registry import backend_for_task
    from tools import browser_vault_tool as vault_tool

    def card_value(field, frame_url=processor + "/card", expression=None):
        """A field of the page's direct child frame at ``frame_url``, read in the frame through the plugin
        (never through a browser tool); None without such a frame."""
        page = backend_for_task(T)
        deadline = time.monotonic() + 20
        while True:
            frames = [f for f in page.child_frames(T) if f["url"] == frame_url]
            if frames or time.monotonic() > deadline:
                break
            time.sleep(0.5)
        if not frames:
            return None
        return page.evaluate_in_frame(T, frames[0]["frame_id"],
                                      expression or f"document.getElementById('{field}').value", secret=False)

    meta = get_vault_store().add_item("payment", "test card", CARD, origin=site)
    asked = []

    def consent(*args, **kwargs):
        asked.append(args[0])
        return "accept"

    with patch.object(vault_tool, "PAYMENT_FRAME_ORIGINS", vault_tool.PAYMENT_FRAME_ORIGINS | {processor}), \
            patch("tools.approval_prompt.request_elicitation_consent", side_effect=consent):
        shop = site.replace("127.0.0.1", "localhost")
        check(call("browser_navigate", url=site + "/checkout-evil").get("success") is True, "/checkout-evil loads")
        check(card_value("number", shop + "/card") == "", "its card frame from the shop-controlled origin is there")
        out = call("browser_vault", action="fill", handle=meta.id)
        check(out.get("error_type") == "no_payment_fields" and not asked,
              "the fill refuses the card frame from an origin the shop controls, without asking")
        check(card_value("number", shop + "/card") == "", "and writes nothing into it")

        # The processor frame is a grandchild here: core never reaches it (no frame is listed for it, and its
        # ancestors are two); refused before consent, so no card is resolved at all.
        check(call("browser_navigate", url=site + "/checkout-nested").get("success") is True, "/checkout-nested loads")
        check(card_value("title", shop + "/wrap", "document.title") == "", "its wrapper frame loads")
        out = call("browser_vault", action="fill", handle=meta.id)
        check(out.get("error_type") == "no_payment_fields" and not asked,
              "the fill refuses a processor frame nested in a shop-controlled frame, without asking")

        check(call("browser_navigate", url=site + "/checkout").get("success") is True, "the checkout loads")
        check(card_value("number") == "", "its card frame from the processor origin is there and empty")
        out = call("browser_vault", action="fill", handle=meta.id)
        check(out.get("success") is True and out.get("frames") == [processor]
              and out.get("fields") == ["cc-csc", "cc-exp", "cc-number"] and out.get("origin") == site
              and len(asked) == 1, "the fill asks once and fills number, expiry and CVC in the processor frame")
        check(card_value("number") == CARD["card_number"] and card_value("cvc") == CARD["cvc"]
              and card_value("expiry") == "12/34", "the processor frame holds the card")
        check(CARD["cvc"] not in last and "4242" not in last, "the result carries no card value")

        other = site.replace("127.0.0.1", "localhost")
        check(call("browser_navigate", url=other + "/checkout").get("success") is True,
              "the same checkout on another origin loads")
        out = call("browser_vault", action="fill", handle=meta.id)
        check(out.get("error_type") == "origin_mismatch" and len(asked) == 1, "the fill refuses another origin")

    requests.delete(f"{bc.get_camofox_url()}/sessions/{bc.get_session(T)['user_id']}",
                    headers=bc._auth_headers(), timeout=30)


def hostile(site, processor):
    import time
    from unittest.mock import patch

    from agent.browser_page_registry import backend_for_task
    from tools import browser_vault_tool as vault_tool

    def leaks(origin):
        time.sleep(1)  # the page's beacons are async
        return requests.get(origin + "/leaks", timeout=10).json()

    def frame_of(url_prefix):
        page = backend_for_task(T)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            frames = [f for f in page.child_frames(T) if f["url"].startswith(url_prefix)]
            if frames:
                return page, frames[0]["frame_id"]
            time.sleep(0.5)
        return page, None

    secrets = [PASSWORD, CARD["card_number"], CARD["cvc"], "12/34", CARD["cardholder_name"]]

    def clean(hits):
        return not any(s in h for h in hits for s in secrets)

    # A hostile login page: the password fill runs, no hook sees it.
    check(call("browser_navigate", url=site + "/login-hostile").get("success") is True, "/login-hostile loads")
    page = backend_for_task(T)
    check(page.evaluate(T, "typeof window.hermesPageMarker", secret=False) == "undefined"
          and page.evaluate(T, "typeof document.wrappedJSObject", secret=False) == "object",
          "Camofox evaluates in an Xray sandbox, not the page's world")
    check(any("hook-control-marker" in h for h in leaks(site)), "control: the page's hooks report a sloppy caller")
    meta = get_vault_store().add_item("login", "hostile", {"identifier_type": "username", "identifier": "alice",
                                                           "password": PASSWORD}, origin=site)
    out = call("browser_vault", action="fill", handle=meta.id)
    check(out.get("success") is True and out.get("filled_fields") == 1, "the password is filled on the hostile login page")
    check(password_length() == len(PASSWORD), "the password field holds it")
    hits = leaks(site)
    check(clean(hits), f"no hook on the login page saw the password ({len(hits)} hook hits)")

    card_meta = get_vault_store().add_item("payment", "hostile card", CARD, origin=site)
    asked = []

    def consent(*args, **kwargs):
        asked.append(args)
        return "accept"

    with patch.object(vault_tool, "PAYMENT_FRAME_ORIGINS", vault_tool.PAYMENT_FRAME_ORIGINS | {processor}), \
            patch("tools.approval_prompt.request_elicitation_consent", side_effect=consent):
        # A hostile processor frame: the card fill runs, no hook sees it.
        check(call("browser_navigate", url=site + "/checkout-hostile").get("success") is True, "/checkout-hostile loads")
        page, fid = frame_of(processor + "/card-hostile")
        check(fid is not None, "its hooked card frame is there")
        leaks(processor)
        out = call("browser_vault", action="fill", handle=card_meta.id)
        check(out.get("success") is True and out.get("frames") == [processor], "the card is filled into the hooked frame")
        page, fid = frame_of(processor + "/card-hostile")  # the vault's own listing retired the earlier id
        check(page.evaluate_in_frame(T, fid, "document.getElementById('number').value", secret=False) == CARD["card_number"],
              "the frame holds the card")
        check(len(asked) == 1 and processor in asked[0][1], "consent named the processor frame's origin")
        hits = leaks(processor)
        check(clean(hits), f"no hook in the card frame saw the card ({len(hits)} hook hits)")

        # The navigation race: right after the vault's value-free check, the checkout's own code moves the
        # card frame to a hostile page on another origin (here the shop's: http://localhost:<site port>).
        check(call("browser_navigate", url=site + "/checkout-hostile").get("success") is True, "/checkout-hostile reloads")
        frame_of(processor + "/card-hostile")
        attacker = site.replace("127.0.0.1", "localhost")
        real_check = vault_tool._precheck_failure

        attacker_hits = []

        def check_then_hijack(evaluate, chk):
            res = real_check(evaluate, chk)
            if chk.ancestor:  # a frame write's phase 1 just passed
                backend_for_task(T).evaluate(T, f"document.getElementById('card').src = {json.dumps(attacker + '/card-hostile')}",
                                             secret=False)
                # Wait for the hostile page to run (its hooks' control beacon), without listing frames:
                # a new listing would retire the frame id the vault is about to write to.
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline and not any("hook-control-marker" in h for h in attacker_hits):
                    attacker_hits.extend(requests.get(attacker + "/leaks", timeout=10).json())
                    time.sleep(0.5)
            return res

        leaks(attacker)
        with patch.object(vault_tool, "_precheck_failure", side_effect=check_then_hijack):
            out = call("browser_vault", action="fill", handle=card_meta.id)
        check(any("hook-control-marker" in h for h in attacker_hits), "the checkout moved the card frame to the hostile page")
        check(out.get("success") is False and out.get("error_type") == "origin_changed",
              "the write into the hijacked frame is refused by its own origin check")
        hits = attacker_hits + leaks(attacker)
        check(clean(hits), f"the hostile page the frame moved to got no card ({len(hits)} hook hits)")
        page, fid = frame_of(attacker + "/card-hostile")
        check(fid is not None and page.evaluate_in_frame(T, fid, "document.getElementById('number').value",
                                                         secret=False) == "", "and its fields stay empty")

    requests.delete(f"{bc.get_camofox_url()}/sessions/{bc.get_session(T)['user_id']}",
                    headers=bc._auth_headers(), timeout=30)


if __name__ == "__main__":
    if sys.argv[1] == "card":
        card(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "hostile":
        hostile(sys.argv[2], sys.argv[3])
    else:
        vault(sys.argv[2])
    print("ALL PASSED", flush=True)
