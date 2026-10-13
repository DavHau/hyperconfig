"""Verdict and anti-bot vendor detection for one page load.

Patterns extend the ones in ianlpaterson/anti-detect-browser-bench (MIT).
Unlike that bench, the verdict is taken from the *final* main-frame document,
so a JS challenge that the browser solved (403 then 200 with real content)
counts as ok; the full status chain is kept in the record for re-scoring.
"""
from __future__ import annotations

import re

VERDICTS = ("ok", "gated", "blocked", "error")

BLOCKED_STATUSES = {401, 403, 406, 429, 451, 503}

# Markers flagged `True` also appear on normal pages that merely embed the
# vendor's sensor or a form captcha, so they only count on interstitial-sized
# bodies.
SMALL_BODY = 20_000

# Explicit refusal pages: no challenge to pass.
_BLOCK_MARKERS = [
    ("cloudflare-block", r"sorry, you have been blocked|error code:? 1020|cf-error-details", False),
    ("cloudfront-block", r"the request could not be satisfied", False),
    ("akamai-block", r"access denied.{0,400}reference\s*#|errors\.edgesuite\.net", False),
    ("f5-block", r"your support id is", False),
    ("ip-block", r"ip-bereich vorübergehend gesperrt|your ip (address )?has been blocked", False),
    ("generic-block", r"request blocked|access to this page has been denied", True),
]

# Challenge / captcha interstitials: a real browser might get through.
_GATE_MARKERS = [
    ("cloudflare-challenge", r"just a moment\.\.\.|cf_chl_opt|"
                             r"enable javascript and cookies to continue|checking your browser", False),
    ("cloudflare-challenge", r"cdn-cgi/challenge-platform", True),
    ("turnstile", r"challenges\.cloudflare\.com/turnstile", True),
    ("datadome", r"captcha-delivery\.com", False),
    ("perimeterx", r"px-captcha|press (&amp;|&) hold", False),
    ("imperva", r"_incapsula_resource|incapsula incident", True),
    ("radware", r"perfdrive\.com|shieldsquare", True),
    ("akamai-bm", r"bm-verify|sec-if-cpt", False),
    ("aws-waf", r"awswaf|aws-waf-token", True),
    ("vercel-checkpoint", r"vercel security checkpoint", False),
    ("recaptcha", r"google\.com/recaptcha|g-recaptcha", True),
    ("hcaptcha", r"hcaptcha\.com", True),
    ("js-verify", r"requires javascript to verify|establishing a secure connection|"
                  r"verify(ing)? (that )?you are (a )?human|captcha challenge", False),
]

_GATE_TITLE = re.compile(
    r"just a moment|attention required|captcha|security check|verif(y|ying)|"
    r"are you a (human|robot)|robot check|checking your browser|^error$",
    re.I,
)

_BLOCK_RE = [(n, re.compile(p, re.I | re.S), s) for n, p, s in _BLOCK_MARKERS]
_GATE_RE = [(n, re.compile(p, re.I | re.S), s) for n, p, s in _GATE_MARKERS]

# (vendor, header name, header value regex or None for "present")
_VENDOR_HEADERS = [
    ("cloudflare", "cf-ray", None),
    ("cloudflare", "server", r"cloudflare"),
    ("cloudfront", "x-amz-cf-id", None),
    ("cloudfront", "via", r"cloudfront"),
    ("akamai", "server", r"akamai"),
    ("akamai", "x-akamai-transformed", None),
    ("datadome", "x-datadome", None),
    ("datadome", "server", r"datadome"),
    ("imperva", "x-iinfo", None),
    ("imperva", "x-cdn", r"imperva|incapsula"),
    ("aws-waf", "x-amzn-waf-action", None),
    ("vercel", "x-vercel-mitigated", None),
    ("kasada", "x-kpsdk-ct", None),
    ("fastly", "x-served-by", r"cache-"),
]
_VENDOR_BODY = [
    ("cloudflare", r"cdn-cgi/challenge-platform|cf-error-details|__cf_chl"),
    ("akamai", r"akamaitechnologies|errors\.edgesuite\.net|/_sec/cp_challenge"),
    ("datadome", r"captcha-delivery\.com|datadome"),
    ("perimeterx", r"px-cdn\.net|perimeterx|/_px/"),
    ("imperva", r"_incapsula_resource|incapsula"),
    ("radware", r"perfdrive|shieldsquare"),
    ("f5", r"your support id is"),
    ("aws-waf", r"awswaf"),
    ("kasada", r"kpsdk"),
]
_VENDOR_BODY_RE = [(n, re.compile(p, re.I)) for n, p in _VENDOR_BODY]

SCAN_BYTES = 60_000


def vendors(headers: dict[str, str], body: str) -> list[str]:
    """Anti-bot/CDN vendors visible in the final response; order of first evidence."""
    h = {k.lower(): v for k, v in (headers or {}).items()}
    found: list[str] = []
    for name, key, pat in _VENDOR_HEADERS:
        v = h.get(key)
        if v is not None and (pat is None or re.search(pat, v, re.I)) and name not in found:
            found.append(name)
    head = (body or "")[:SCAN_BYTES]
    for name, rx in _VENDOR_BODY_RE:
        if name not in found and rx.search(head):
            found.append(name)
    return found


def verdict(status: int | None, title: str, body: str, error: str | None) -> tuple[str, str | None]:
    """(verdict, marker) for the final main-frame document."""
    if error and status is None and not body:
        return "error", None
    head = (body or "")[:SCAN_BYTES]
    small = len(body or "") < SMALL_BODY
    for name, rx, small_only in _BLOCK_RE:
        if (small or not small_only) and rx.search(head):
            return "blocked", name
    for name, rx, small_only in _GATE_RE:
        if (small or not small_only) and rx.search(head):
            return "gated", name
    if re.search(r"access denied|forbidden", title or "", re.I):
        return "blocked", "title"
    if _GATE_TITLE.search(title or ""):
        return "gated", "title"
    if status in BLOCKED_STATUSES:
        return "blocked", f"http-{status}"
    if status is None or status >= 400:
        return "error", f"http-{status}"
    if head and len(head) < 800 and "<script" not in head.lower() and not head.lstrip().startswith(("{", "[")):
        return "gated", "tiny-body"
    return "ok", None
