"""Fetch setups. Each one turns a URL into a raw page observation.

A setup is opened once per sweep; `load()` starts from a clean identity on
every call (fresh HTTP session, or a fresh browser with a new temporary
profile that is deleted afterwards), so cookies and challenge clearances
never carry over between targets.

To add a browser engine, add one `BrowserSetup` to `SETUPS` whose
`launch_options` returns the Playwright `launch_persistent_context` keyword
arguments for that engine, and add the engine to default.nix.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from html import unescape
from typing import Callable, Iterator
from contextlib import contextmanager

NAV_TIMEOUT_S = 45
NETWORKIDLE_S = 10
MAX_HOPS = 10  # main-frame navigations (redirects, challenge reloads) per load

_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)


class NavDenied(Exception):
    """A main-frame navigation was refused by the guard."""


# Called with every main-frame URL before it is requested; raises NavDenied.
Guard = Callable[[str], None]


@dataclass
class Observation:
    status: int | None = None
    statuses: list[int] = field(default_factory=list)
    final_url: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    title: str = ""
    body: str = ""
    error: str | None = None


def _title(body: str) -> str:
    m = _TITLE_RE.search(body or "")
    return " ".join(unescape(m.group(1)).split()) if m else ""


# --------------------------------------------------------------------- HTTP


@dataclass
class HttpSetup:
    name: str
    description: str
    session_factory: Callable[[], object]
    engine_version: Callable[[], str]
    needs_display: bool = False

    @contextmanager
    def open(self) -> Iterator["HttpSetup"]:
        yield self

    def load(self, url: str, guard: Guard, settle_s: float) -> Observation:
        del settle_s  # no rendering to wait for
        obs = Observation()
        session = self.session_factory()
        try:
            for _ in range(MAX_HOPS):
                guard(url)
                resp = session.get(url, timeout=NAV_TIMEOUT_S, allow_redirects=False)
                obs.statuses.append(resp.status_code)
                location = resp.headers.get("location")
                if 300 <= resp.status_code < 400 and location:
                    url = _urljoin(url, location)
                    continue
                obs.status = resp.status_code
                obs.final_url = str(resp.url)
                obs.headers = {k.lower(): v for k, v in resp.headers.items()}
                obs.body = resp.text or ""
                obs.title = _title(obs.body)
                return obs
            obs.error = f"more than {MAX_HOPS} redirects"
        except NavDenied as e:
            obs.error = f"NavDenied: {e}"
        except Exception as e:  # noqa: BLE001 - every failure is a result
            obs.error = f"{type(e).__name__}: {str(e)[:300]}"
        finally:
            session.close()
        return obs


def _urljoin(base: str, ref: str) -> str:
    from urllib.parse import urljoin
    return urljoin(base, ref)


def _requests_session():
    import requests
    return requests.Session()


def _requests_version() -> str:
    import requests
    return f"requests {requests.__version__}"


def _cffi_session():
    from curl_cffi import requests as creq
    return creq.Session(impersonate="chrome")


def _cffi_version() -> str:
    import curl_cffi
    return f"curl_cffi {curl_cffi.__version__} (impersonate=chrome)"


# ------------------------------------------------------------------ Browser


@dataclass
class BrowserSetup:
    name: str
    description: str
    engine: str  # Playwright browser type: chromium | firefox
    launch_options: Callable[[], dict]
    needs_display: bool = False

    @contextmanager
    def open(self) -> Iterator["BrowserSetup"]:
        from playwright.sync_api import sync_playwright
        exe = self.launch_options().get("executable_path")
        self._version = subprocess.run([exe, "--version"], capture_output=True, text=True,
                                       timeout=30).stdout.strip() if exe else "unknown"
        with sync_playwright() as p:
            self._type = getattr(p, self.engine)
            yield self

    def engine_version(self) -> str:
        return self._version

    def load(self, url: str, guard: Guard, settle_s: float) -> Observation:
        obs = Observation()
        profile = tempfile.mkdtemp(prefix=f"web-bench-{self.name}-")
        ctx = None
        try:
            ctx = self._type.launch_persistent_context(profile, **self.launch_options())
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.set_default_timeout(NAV_TIMEOUT_S * 1000)
            page.set_default_navigation_timeout(NAV_TIMEOUT_S * 1000)

            def route(r):
                req = r.request
                if req.is_navigation_request() and req.frame.parent_frame is None:
                    try:
                        guard(req.url)
                    except NavDenied as e:
                        obs.error = f"NavDenied: {e}"
                        r.abort("blockedbyclient")
                        return
                r.continue_()

            def on_response(resp):
                try:
                    if resp.request.is_navigation_request() and resp.frame.parent_frame is None:
                        obs.statuses.append(resp.status)
                        obs.status = resp.status
                        obs.headers = dict(resp.headers)
                except Exception:  # noqa: BLE001 - frame may be gone mid-navigation
                    pass

            page.route("**/*", route)
            page.on("response", on_response)
            page.goto(url, wait_until="domcontentloaded")
            try:
                page.wait_for_load_state("networkidle", timeout=NETWORKIDLE_S * 1000)
            except Exception:  # noqa: BLE001 - beacons keep some pages busy forever
                pass
            time.sleep(settle_s)
            obs.title, obs.body = _read_page(page)
            if obs.body and len(obs.body) < 5000 and re.search(r"cf_chl_opt|perfdrive|_incapsula_", obs.body, re.I):
                time.sleep(3)  # interstitial shims reload into the real page or the block page
                obs.title, obs.body = _read_page(page)
            obs.final_url = page.url
        except Exception as e:  # noqa: BLE001 - every failure is a result
            if not obs.error:
                obs.error = f"{type(e).__name__}: {str(e).splitlines()[0][:300]}"
        finally:
            if ctx is not None:
                try:
                    ctx.close()
                except Exception:  # noqa: BLE001
                    pass
            shutil.rmtree(profile, ignore_errors=True)
        return obs


def _read_page(page) -> tuple[str, str]:
    for _ in range(2):
        try:
            return page.title() or "", page.content() or ""
        except Exception:  # noqa: BLE001 - page navigated while reading
            time.sleep(2)
    return "", ""


def _chromium(headless: bool) -> Callable[[], dict]:
    def options() -> dict:
        return {"executable_path": os.environ["WEB_BENCH_CHROMIUM"], "headless": headless}
    return options


def _camoufox(headless: bool) -> Callable[[], dict]:
    """Camoufox launch options; every call draws a fresh fpgen identity."""
    def options() -> dict:
        from camoufox import DefaultAddons
        from camoufox.utils import STOCK_MEDIA_DEFAULTS, launch_options, spoofs_window_dimensions
        opts = launch_options(
            executable_path=os.environ["WEB_BENCH_CAMOUFOX"], headless=headless,
            os="linux", locale="en-US", humanize=True,  # Linux persona: coherent with the host's TLS/fonts/X
            exclude_addons=[DefaultAddons.UBO],  # it would be fetched from addons.mozilla.org per launch
        )
        # What camoufox.sync_api.NewBrowser adds for a persistent context:
        # Playwright's default viewport deadlocks Juggler on a spoofed window,
        # and its default media emulation overrides the host's answers.
        if spoofs_window_dimensions(opts):
            opts["no_viewport"] = True
        return {**STOCK_MEDIA_DEFAULTS, **opts}
    return options


# Default sweep order: least bot-like first, so a reputation hit caused by an
# obvious bot client cannot bias the setups that follow it on the same domain.
SETUPS: dict[str, HttpSetup | BrowserSetup] = {
    s.name: s
    for s in [
        BrowserSetup("camoufox-headful", "Camoufox (anti-detect Firefox), Linux persona, headful under Xvfb",
                     "firefox", _camoufox(False), needs_display=True),
        BrowserSetup("chromium-headful", "nixpkgs Chromium, headful under Xvfb, via Playwright",
                     "chromium", _chromium(False), needs_display=True),
        HttpSetup("curl_cffi", "curl_cffi Session, impersonate=chrome (TLS/HTTP2 like Chrome)",
                  _cffi_session, _cffi_version),
        BrowserSetup("camoufox-headless", "Camoufox (anti-detect Firefox), Linux persona, headless",
                     "firefox", _camoufox(True)),
        BrowserSetup("chromium-headless", "nixpkgs Chromium, headless, via Playwright (~ hermes agent-browser)",
                     "chromium", _chromium(True)),
        HttpSetup("requests", "python requests, default headers (~ agents' raw curl/urllib)",
                  _requests_session, _requests_version),
    ]
}
