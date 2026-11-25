"""The whole card purchase on a hosted checkout, for the browser check (default.nix): run as alice
with hermes' own interpreter, through hermes' tool registry like the agent loop, against her real
camofox-browser (as every agent's browser module builds it) and site.py's /checkout-hosted.

  checkout <shop> <processor>
      The shop page embeds the processor's card frame (cross-origin); the card frame embeds two
      more cross-origin frames: /agree (a ref button and an unlabelled Confirm button) and the
      captcha (captcha-site.py). In order:
        - browser_vault fill writes the TEST card into the processor frame (consent stubbed: no
          prompt headless) and its result carries no card value;
        - browser_snapshot (whole, scope=, diff=) shows the filled fields as the mask, never a card
          value, in any form (digits grouped or not, expiry, CVC);
        - browser_vision's screenshot (the image the model would get) has no card value: OCR finds
          none, while the control, the same page with the same TEST card typed by the page into an
          unfilled field, OCR does read; the pixels of the filled fields' boxes are the mask's;
        - the page re-creates a filled field with the value regrouped: still masked;
        - browser_click with a ref clicks "I agree" inside the frame nested in the card frame;
        - browser_click with x, y (from the screenshot's viewport) clicks the unlabelled Confirm button
          there;
        - browser_solve_captcha solves the captcha two frames down;
        - browser_click on Pay submits the form: the processor receives the real card values;
        - after the submit (the filled fields gone), browser_vision works and shows no mask.
      Fail closed: when masking a filled field fails, browser_vision is refused (capture_refused) and
      sends nothing.

Exits 1 on the first failed check; every check prints a PASS/FAIL line.
"""
import base64
import io
import json
import os
import subprocess
import sys
import time

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

import importlib  # noqa: E402
from unittest.mock import patch  # noqa: E402

import requests  # noqa: E402
from PIL import Image  # noqa: E402

import model_tools  # noqa: E402,F401  (discovers the plugins)

bc = importlib.import_module("hermes_plugins.camofox.camofox_client")
tools = importlib.import_module("hermes_plugins.camofox.camofox_tools")
from agent.browser_page_registry import backend_for_task  # noqa: E402
from agent.vault_store import get_vault_store  # noqa: E402
from tools import browser_vault_tool as vault_tool  # noqa: E402
from tools.registry import registry  # noqa: E402

TESSERACT = os.environ["TESSERACT"]
# A test card number (Stripe's), never a real one.
CARD = {"card_number": "4242424242424242", "cardholder_name": "Test User", "exp_month": "12", "exp_year": "2034",
        "cvc": "987", "billing_postal_code": "10115"}
SECRETS = ["4242424242424242", "4242 4242 4242 4242", "4242-4242-4242-4242", "12/34", "987"]
T = "checkout-a"


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def clean(text):
    return not any(s in text for s in SECRETS)


def call(name, **args):
    out = registry.dispatch(name, args, task_id=T)
    shown = out if isinstance(out, str) else json.dumps({k: v for k, v in out.items() if k != "content"})
    print(f"--- {name}({json.dumps(args)}) -> {shown[:600]}", flush=True)
    return out


def call_json(name, **args):
    out = call(name, **args)
    check(clean(out), f"{name} carries no card value")
    return json.loads(out)


def events(origin):
    return requests.get(origin + "/events", timeout=10).json()


def ocr(images) -> str:
    """The text tesseract reads in each of ``images`` (raw image bytes), joined."""
    out = []
    for raw in images:
        buf = io.BytesIO()
        Image.open(io.BytesIO(raw)).convert("RGB").save(buf, "PNG")
        out.append(subprocess.run([TESSERACT, "stdin", "stdout", "--psm", "11"], input=buf.getvalue(),
                                  capture_output=True, check=True).stdout.decode(errors="replace"))
    return "\n".join(out)


def digits(text: str) -> str:
    return "".join(ch for ch in text if ch.isdigit())


def vision_image():
    """browser_vision's screenshot, the result, and the image as the model receives it (the native
    attachment, a resized JPEG). OCR runs on both: the full-size PNG reads best, the attachment is
    what leaves the host."""
    with patch("tools.vision_tools._should_use_native_vision_fast_path", return_value=True):
        out = call("browser_vision", question="What does the checkout show?")
    if isinstance(out, str):
        return None, json.loads(out)
    url = next(p["image_url"]["url"] for p in out["content"] if p.get("type") == "image_url")
    head, _, data = url.partition(",")
    check(head.startswith("data:image/"), "the attachment is an image")
    with open(out["meta"]["screenshot_path"], "rb") as f:
        return [f.read(), base64.b64decode(data)], out


def processor_frame(page, processor):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        frames = [f for f in page.child_frames(T) if f["url"].startswith(processor + "/hosted-card")]
        if frames:
            return frames[0]["frame_id"]
        time.sleep(0.5)
    return None


def checkout(shop, processor):
    # /state reads and clears: drop a solve an earlier subtest (captcha.py) left there.
    requests.get("http://127.0.0.1:8766/state", timeout=10)
    meta = get_vault_store().add_item("payment", "test card", CARD, origin=shop)
    asked = []

    def consent(*args, **kwargs):
        asked.append(args[0])
        return "accept"

    events(processor), events(shop)
    check(call_json("browser_navigate", url=shop + "/checkout-hosted").get("success") is True, "the hosted checkout loads")
    page = backend_for_task(T)
    fid = processor_frame(page, processor)
    check(fid is not None, "its card frame from the processor origin is there")

    # Control first: OCR reads a card number the PAGE wrote (not the vault) in the shop's own field.
    page.evaluate(T, "(() => { document.getElementById('ref').value = '4242 4242 4242 4242'; return 1; })()", secret=False)
    # (the page's fonts and frames settle first: OCR of a half-drawn page reads nothing)
    for _ in range(5):
        png, _ = vision_image()
        seen = ocr(png) if png is not None else ""
        if "4242424242424242" in digits(seen):
            break
        time.sleep(1)
    print("OCR control:", " ".join(seen.split())[:200], flush=True)
    check("4242424242424242" in digits(seen), "control: OCR reads a card number on the page")
    page.evaluate(T, "(() => { document.getElementById('ref').value = ''; return 1; })()", secret=False)

    with patch.object(vault_tool, "PAYMENT_FRAME_ORIGINS", vault_tool.PAYMENT_FRAME_ORIGINS | {processor}), \
            patch("tools.approval_prompt.request_elicitation_consent", side_effect=consent):
        out = call_json("browser_vault", action="fill", handle=meta.id)
    check(out.get("success") is True and out.get("frames") == [processor] and len(asked) == 1,
          "the vault fills the card into the processor frame after one confirmation")
    fid = processor_frame(page, processor)
    real = page.evaluate_in_frame(T, fid, "document.getElementById('number').value + '|' + document.getElementById('cvc').value",
                                  secret=False)
    check(real == CARD["card_number"] + "|" + CARD["cvc"], "the frame holds the real card")

    # Snapshots: whole, scoped and as a diff, never a value; the filled fields show as the mask.
    snap = call_json("browser_snapshot")
    check("••••" in snap["snapshot"], "the snapshot shows the filled fields as the mask")
    scoped = call_json("browser_snapshot", scope="iframe")
    check(scoped.get("scope") == "iframe" and "••••" in scoped["snapshot"] and len(scoped["snapshot"]) <= len(snap["snapshot"]),
          "a snapshot scoped to the frames is no bigger and masked")
    again = call_json("browser_snapshot", diff=True)
    check(again.get("diff") is True and again["snapshot"] == "(unchanged)", "diff=true on an unchanged page says so")
    images = call_json("browser_get_images")
    check(images.get("success") is True, "browser_get_images works on the filled page")

    # The screenshot the model gets: no card value, read by OCR or present as pixels of the field.
    png, vis = vision_image()
    check(png is not None, "browser_vision returns the screenshot")
    text = ocr(png)
    print("OCR:", " ".join(text.split())[:400], flush=True)
    check("4242424242424242" not in digits(text) and "4242" not in text and "987" not in text,
          "OCR finds no card value in the screenshot (the field, nor the page's previews mirroring it, whole or in spans; the shop's root is narrower than the viewport)")
    check(page.evaluate_in_frame(T, fid, "document.getElementById('preview').textContent", secret=False)
          == "4242 4242 4242 4242", "control: the card preview mirrors the number as the page's own text")
    check(page.evaluate_in_frame(T, fid, "document.getElementById('groups').textContent.replace(/\\s/g, '')", secret=False)
          == "4242424242424242", "control: a second preview splits the number into one span per group")
    vp = vis["meta"].get("viewport") or {}
    check(vp.get("width", 0) > 0, "the screenshot names its viewport for coordinate clicks")
    # Pixels: the card number field's box (shop frame at y 60, field at the card frame's top left; CSS px
    # times the screenshot's scale) holds only the mask's two greys, no text.
    full = Image.open(io.BytesIO(png[0])).convert("RGB")
    scale = full.width / vp["width"]
    box = full.crop((int(12 * scale), int(66 * scale), int(200 * scale), int(84 * scale)))
    colours = {c for _, c in box.getcolors(1 << 20)}
    print("field pixels:", sorted(colours)[:6], flush=True)
    check(colours <= {(0x33, 0x33, 0x33), (0x77, 0x77, 0x77)}, "the card number field is painted over in the image")

    # The page swaps the filled field for a new one holding the value regrouped: still masked.
    page.evaluate_in_frame(T, fid, "(() => { const o = document.getElementById('number'); const e = o.cloneNode(); "
                                   "e.value = o.value.replace(/(\\d{4})(?=\\d)/g, '$1 '); o.replaceWith(e); return 1; })()",
                           secret=False)
    page.evaluate_in_frame(T, fid, "(() => { const o = document.getElementById('cvc'); const e = o.cloneNode(); "
                                   "e.value = o.value; o.replaceWith(e); return 1; })()", secret=False)
    snap = call_json("browser_snapshot")
    png, _ = vision_image()
    seen = ocr(png) if png is not None else ""
    check(png is not None and "4242" not in seen and "987" not in seen,
          "re-created fields holding the values (number regrouped, CVC) are masked too")

    # A ref click inside the frame nested in the card frame.
    snap = call_json("browser_snapshot")["snapshot"]
    ref = next((line.split("[", 1)[1].split("]", 1)[0] for line in snap.split("\n")
                if 'button "I agree"' in line and "[" in line), None)
    check(ref is not None, "the nested frame's button has a ref")
    check(call_json("browser_click", ref="@" + ref).get("success") is True, "browser_click on that ref succeeds")
    deadline = time.monotonic() + 10
    got = []
    while time.monotonic() < deadline and not any(e["event"] == "agreed" for e in got):
        got += events(processor)
        time.sleep(0.3)
    check(any(e["event"] == "agreed" for e in got), "the click reached the button two frames down")

    # A coordinate click: the unlabelled Confirm button sits at (200, 220) of the viewport.
    check(call_json("browser_click", x=200, y=220).get("success") is True, "browser_click at x, y succeeds")
    deadline = time.monotonic() + 10
    got = []
    while time.monotonic() < deadline and not any(e["event"] == "confirmed" for e in got):
        got += events(processor)
        time.sleep(0.3)
    check(any(e["event"] == "confirmed" for e in got), "the coordinate click reached the unlabelled button")
    check(call_json("browser_click", x=99999, y=5).get("success") is False, "a point outside the viewport is refused")

    # A captcha widget too tall for any viewport screenshot: the solver refuses to photograph it
    # (its element screenshot would bypass the mask), the filled card stays on the page.
    tall = call_json("browser_navigate", url="http://127.0.0.1:8766/captcha-tall")
    check(tall.get("success") is True, "a page with a taller-than-viewport captcha loads")
    out = call_json("browser_solve_captcha")
    check(out.get("status") == "failed" and "does not fit the viewport" in str(out.get("reason")),
          "the solver refuses a widget it cannot photograph through the guarded screenshot")
    check(call_json("browser_back").get("success") is True, "back to the checkout")
    fid = processor_frame(page, processor)
    restored = page.evaluate_in_frame(T, fid, "document.getElementById('number').value", secret=False)
    print("after back the number field holds", "a value" if restored else "nothing", flush=True)
    snap = call_json("browser_snapshot")
    png, _ = vision_image()
    seen = ocr(png) if png is not None else ""
    check(png is not None and "4242424242424242" not in digits(seen) and "4242" not in seen,
          "after back/forward no card value shows, however the page came back")
    if not restored:
        with patch.object(vault_tool, "PAYMENT_FRAME_ORIGINS", vault_tool.PAYMENT_FRAME_ORIGINS | {processor}), \
                patch("tools.approval_prompt.request_elicitation_consent", side_effect=consent):
            check(call_json("browser_vault", action="fill", handle=meta.id).get("success") is True, "filled again after back")
    call_json("browser_click", ref="@" + ref)
    call_json("browser_click", x=200, y=220)

    # The captcha, two frames down.
    check(requests.get("http://127.0.0.1:8766/state", timeout=10).json().get("result") == "pending",
          "the captcha is not solved yet")
    out = call_json("browser_solve_captcha")
    check(out.get("status") == "solved", "browser_solve_captcha solves the captcha in the nested frame")
    # (camofox-browser's snapshot leaves captcha frames out by design: the captcha reports to its origin.)
    check(requests.get("http://127.0.0.1:8766/state", timeout=10).json().get("result") == "Verification Success",
          "the captcha frame shows it was solved")
    snap = call_json("browser_snapshot")["snapshot"]

    # Pay: the processor receives the real values.
    pay = next((line.split("[", 1)[1].split("]", 1)[0] for line in snap.split("\n")
                if 'button "Pay"' in line and "[" in line), None)
    check(pay is not None, "the Pay button has a ref")
    check(call_json("browser_click", ref="@" + pay).get("success") is True, "Pay is clicked")
    deadline = time.monotonic() + 15
    paid = []
    while time.monotonic() < deadline and not paid:
        paid = [e for e in events(processor) if e["event"] == "paid"]
        time.sleep(0.3)
    check(len(paid) == 1, "the processor received the form")
    fields = paid[0]["fields"]
    check(digits(fields.get("cardnumber", "")) == CARD["card_number"] and fields.get("cvc") == CARD["cvc"]
          and fields.get("exp-date") == "12/34", "with the real card values")

    # Nothing filled is left: the screenshot is sent unmasked, and still carries no value.
    png, _ = vision_image()
    check(png is not None and "Payment received" in ocr(png), "after the submit browser_vision works as before")

    # Fail closed, a real path: the page strips the mask's style from the field while the capture runs.
    check(call_json("browser_navigate", url=shop + "/checkout-hosted").get("success") is True, "the checkout loads again")
    fid = processor_frame(page, processor)
    with patch.object(vault_tool, "PAYMENT_FRAME_ORIGINS", vault_tool.PAYMENT_FRAME_ORIGINS | {processor}), \
            patch("tools.approval_prompt.request_elicitation_consent", side_effect=consent):
        check(call_json("browser_vault", action="fill", handle=meta.id).get("success") is True, "filled again")
    # (frame ids are per document: list the frames again rather than trust one read before the fill)
    fid = processor_frame(page, processor)
    # (the observer is the page's own code, site.py's stripMask: a callback from the isolated world
    # cannot be handed to the page's MutationObserver)
    check(page.evaluate_in_frame(T, fid, "window.wrappedJSObject.stripMask()", secret=False) == 1,
          "the page arms its mask-stripping observer")
    png, res = vision_image()
    check(png is None and res.get("error_type") == "capture_refused", "browser_vision is refused, no image sent")
    check("lost its mask" in res.get("error", ""), "and says why")

    requests.delete(f"{bc.get_camofox_url()}/sessions/{bc.get_session(T)['user_id']}",
                    headers=bc._auth_headers(), timeout=30)


if __name__ == "__main__":
    checkout(sys.argv[2], sys.argv[3])
    print("ALL PASSED", flush=True)
