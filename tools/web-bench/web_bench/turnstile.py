"""Tick Cloudflare's Turnstile checkbox where DOM selectors cannot reach it.

Cloudflare's challenge page ("Just a moment...") and embedded Turnstile
widgets draw the checkbox in an iframe from challenges.cloudflare.com that is
attached inside a *closed* shadow root, and the box inside that frame sits in
another closed shadow root. CSS/Playwright selectors (CaptchaKraken's
`iframe[src*="challenges.cloudflare.com"]`) see neither, but the browser's
frame tree does: `page.frames` lists the frame, `frame_element()` hands back
its host <iframe>, and its bounding box says where to click on screen.

The click itself is a plain mouse gesture at page coordinates (Camoufox's
`humanize` shapes the cursor path). Firefox must run with
`browser.tabs.remote.useCrossOriginOpenerPolicy=false` (Camoufox
`disable_coop=True`) for the click to reach the cross-origin frame.
"""
from __future__ import annotations

import json
import random
import re
import time
from pathlib import Path
from typing import Callable

CF_HOST = "challenges.cloudflare.com"
# Titles of Cloudflare's interstitial in the languages it localises to most.
_INTERSTITIAL_TITLE = re.compile(r"^(just a moment|einen moment|un instant|un momento|um momento|請稍候|请稍候|しばらくお待ちください)", re.I)
# The checkbox's centre in Turnstile's 300x65 frame: 16 px margin + half a 24 px box.
_BOX_X, _BOX_SIZE = 16 + 12, 24
_MIN_FRAME = (150, 40)  # a smaller frame is the invisible/compact variant, nothing to tick
_CLICK_GAP_S = 8.0  # the widget answers a click within a few seconds; never hammer it
_MAX_CLICKS = 3

Capture = Callable[[str], None]


def challenge_frames(page) -> list:
    return [f for f in page.frames if CF_HOST in (f.url or "")]


def is_interstitial(page) -> bool:
    """Cloudflare's full-page challenge, as opposed to a page that embeds a widget."""
    try:
        if _INTERSTITIAL_TITLE.match((page.title() or "").strip()):
            return True
        return "_cf_chl_opt" in page.content()[:200_000]
    except Exception:  # noqa: BLE001 - mid-navigation
        return True


def _response_token(page) -> bool:
    try:
        return any(v for v in page.locator('input[name="cf-turnstile-response"]').evaluate_all(
            "els => els.map(e => e.value)"))
    except Exception:  # noqa: BLE001
        return False


def widget_box(page) -> dict | None:
    """Page-coordinate box of the first drawn Turnstile frame, or None."""
    for frame in challenge_frames(page):
        try:
            box = frame.frame_element().bounding_box()
        except Exception:  # noqa: BLE001 - frame detached mid-look
            continue
        if box and box["width"] >= _MIN_FRAME[0] and box["height"] >= _MIN_FRAME[1]:
            return box
    return None


def _checkbox_point(page, box: dict) -> tuple[float, float, str]:
    """Where to click: the tick box found on a capture of the frame (OpenCV, CaptchaKraken's
    finder), else Turnstile's fixed layout. Returns (x, y, how)."""
    try:
        import tempfile

        from captchakraken.tool_calls.find_checkbox import find_checkbox
        with tempfile.NamedTemporaryFile(suffix=".png") as f:
            page.screenshot(path=f.name, clip=box, scale="css", timeout=10_000)
            found = find_checkbox(f.name)
        if found:
            x, y, w, h = found
            return (box["x"] + x + w * random.uniform(0.3, 0.7),
                    box["y"] + y + h * random.uniform(0.3, 0.7), "opencv")
    except Exception:  # noqa: BLE001 - no OpenCV or capture refused: the layout is well known
        pass
    jitter = _BOX_SIZE * 0.2
    return (box["x"] + _BOX_X + random.uniform(-jitter, jitter),
            box["y"] + box["height"] / 2 + random.uniform(-jitter, jitter), "layout")


def _click(page, x: float, y: float) -> None:
    page.mouse.move(x, y)  # Camoufox humanize draws the path
    time.sleep(random.uniform(0.15, 0.45))
    page.mouse.down()
    time.sleep(random.uniform(0.06, 0.16))
    page.mouse.up()


def solve(page, budget_s: float, capture: Capture | None = None) -> dict:
    """Wait for Cloudflare's widget, tick it (at most a few times), and wait for the page to clear.

    `solved` means: an interstitial navigated away to a non-challenge page, or an embedded
    widget produced its response token. Every outcome is a result, never an exception.
    """
    out: dict = {"attempted": True, "solved": False, "kind": None, "clicks": [], "frames": 0, "error": None}
    t0 = time.monotonic()
    deadline = t0 + budget_s
    interstitial = is_interstitial(page)
    out["kind"] = "interstitial" if interstitial else ("widget" if challenge_frames(page) else None)
    if capture:
        capture("before")
    last_click = 0.0
    try:
        while time.monotonic() < deadline:
            frames = challenge_frames(page)
            out["frames"] = max(out["frames"], len(frames))
            if interstitial and not is_interstitial(page):
                out["solved"] = True
                break
            if not interstitial and _response_token(page):
                out["solved"] = True
                break
            if not interstitial and not frames and time.monotonic() - t0 > 15:
                out["error"] = "no Cloudflare challenge frame on this page"
                break
            box = widget_box(page)
            if box and len(out["clicks"]) < _MAX_CLICKS and time.monotonic() - last_click > _CLICK_GAP_S:
                time.sleep(random.uniform(0.8, 2.0))  # a person reads the box first
                box = widget_box(page)
                if box:
                    x, y, how = _checkbox_point(page, box)
                    if capture and not out["clicks"]:
                        capture("widget")
                    _click(page, x, y)
                    last_click = time.monotonic()
                    out["clicks"].append({"t_ms": int((last_click - t0) * 1000), "how": how,
                                          "frame": {k: round(v) for k, v in box.items()},
                                          "at": [round(x), round(y)]})
            time.sleep(1.0)
        else:
            out["error"] = "challenge still up at the deadline"
    except Exception as e:  # noqa: BLE001 - page closed, navigation races
        out["error"] = f"{type(e).__name__}: {(str(e).splitlines() or [''])[0][:300]}"
    out["duration_ms"] = int((time.monotonic() - t0) * 1000)
    if capture:
        capture("after")
    return out


def capturer(page, directory: Path, prefix: str) -> Capture:
    """A Capture writing, per tag, a viewport screenshot, the light-DOM HTML and a frame-tree
    dump (url, box, what the DOM can reach), for diagnosing challenge pages after the fact."""
    def capture(tag: str) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        base = directory / f"{prefix}-{tag}"
        try:
            page.screenshot(path=f"{base}.png", timeout=10_000)
        except Exception:  # noqa: BLE001
            pass
        frames = []
        for i, f in enumerate(page.frames):
            info: dict = {"i": i, "url": (f.url or "")[:300], "name": f.name, "child": f.parent_frame is not None}
            try:
                el = f.frame_element() if f.parent_frame else None
                info["box"] = el.bounding_box() if el else None
                # Is the host <iframe> in the light DOM, or inside a shadow root?
                info["host_in_light_dom"] = el.evaluate("e => e.getRootNode() === e.ownerDocument") if el else None
            except Exception as e:  # noqa: BLE001
                info["box_error"] = str(e).splitlines()[0][:200]
            try:
                info["dom"] = f.evaluate("""() => ({
                    title: document.title,
                    bodyShadowOpen: !!(document.body && document.body.shadowRoot),
                    checkboxesInLightDom: document.querySelectorAll('input[type=checkbox]').length,
                    text: (document.body ? document.body.innerText : '').slice(0, 400)})""")
            except Exception as e:  # noqa: BLE001
                info["dom_error"] = str(e).splitlines()[0][:200]
            frames.append(info)
        try:
            html = page.content()
        except Exception:  # noqa: BLE001
            html = ""
        dump = {"url": page.url, "title": _safe(page.title), "frames": frames,
                "selector_iframe_cf": _count(page, f'iframe[src*="{CF_HOST}"]'),
                "selector_cf_turnstile": _count(page, ".cf-turnstile"),
                "selector_response": _count(page, 'input[name="cf-turnstile-response"]')}
        Path(f"{base}.json").write_text(json.dumps(dump, indent=1))
        Path(f"{base}.html").write_text(html[:300_000])
    return capture


def _safe(fn):
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return None


def _count(page, selector: str) -> int | None:
    try:
        return page.locator(selector).count()
    except Exception:  # noqa: BLE001
        return None
