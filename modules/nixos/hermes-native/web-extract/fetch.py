"""Fetch one URL and print its readable content as one JSON object.

Usage: fetch.py URL [markdown|text]

Output: {"url", "title", "content"} or {"url", "error", "kind", "status"}.
The fetch impersonates Chrome's TLS/HTTP2 fingerprint (curl_cffi);
trafilatura keeps the main content of HTML, pymupdf reads PDFs. Errors
say why a page failed (blocked, rate limited, needs JavaScript, missing,
network), so the agent can pick the next step instead of retrying.
"""

import ipaddress
import json
import socket
import sys
from urllib.parse import urljoin, urlsplit

from curl_cffi import requests
from curl_cffi.requests.exceptions import RequestException

IMPERSONATE = "chrome"
TIMEOUT = 30  # seconds per request
MAX_REDIRECTS = 8
MAX_BYTES = 25 * 1024 * 1024
# Below this much extracted text a page is a shell: a challenge
# interstitial or a JavaScript app.
THIN_TEXT = 300

# Markers of an anti-bot interstitial, matched in the lowercased head of
# the body. Normal pages carry some vendor scripts too (Cloudflare injects
# /cdn-cgi/challenge-platform everywhere), so these only count on an
# error status or a page with almost no text.
CHALLENGE_MARKERS = {
    "Cloudflare": (
        "<title>just a moment...</title>",
        "cf-browser-verification",
        "cf_chl_opt",
        "attention required! | cloudflare",
        "enable javascript and cookies to continue",
    ),
    "DataDome": ("captcha-delivery.com", "geo.captcha-delivery"),
    "PerimeterX": ("px-captcha", "_pxappid"),
    "Imperva": ("_incapsula_resource", "incapsula incident"),
    "Akamai": ("access denied</title>", "errors.edgesuite.net"),
    "AWS WAF": ("awswaf", "aws-waf-token"),
    "Sucuri": ("sucuri website firewall",),
    "CAPTCHA": ("g-recaptcha", "h-captcha", "hcaptcha.com", "cf-turnstile", "captcha challenge"),
}
JS_MARKERS = (
    "enable javascript",
    "requires javascript",
    "javascript is required",
    "javascript is disabled",
    "you need to enable javascript",
    "verify your browser",
)


class Failure(Exception):
    def __init__(self, kind, message, status=None):
        super().__init__(message)
        self.kind = kind
        self.status = status


def vendor_of(headers, head):
    """Anti-bot vendor named by the response headers or body markers, or None."""
    server = headers.get("server", "").lower()
    if "cf-ray" in headers or server == "cloudflare":
        hint = "Cloudflare"
    elif "x-datadome" in headers or "datadome" in headers.get("set-cookie", "").lower():
        hint = "DataDome"
    elif "akamaighost" in server:
        hint = "Akamai"
    elif "x-amzn-waf-action" in headers or "x-amz-cf-id" in headers:
        hint = "AWS CloudFront/WAF"
    else:
        hint = None
    for vendor, markers in CHALLENGE_MARKERS.items():
        if any(m in head for m in markers):
            return vendor if vendor != "CAPTCHA" or hint is None else f"{hint} CAPTCHA"
    return hint


def challenge_in(head):
    return any(m in head for markers in CHALLENGE_MARKERS.values() for m in markers)


def check_public(url):
    """Refuse hosts that resolve to private, loopback or link-local addresses."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise Failure("invalid_url", f"Not an http(s) URL: {url}")
    try:
        infos = socket.getaddrinfo(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80))
    except socket.gaierror:
        raise Failure("network", f"DNS lookup failed for {parts.hostname}: the host does not exist or DNS is down. Check the URL; do not guess hostnames.")
    for info in infos:
        addr = ipaddress.ip_address(info[4][0].split("%", 1)[0])
        if not addr.is_global:
            raise Failure("private_address", f"Blocked: {parts.hostname} resolves to a private or internal address ({addr}).")


def network_failure(url, exc):
    host = urlsplit(url).hostname
    text = str(exc)
    code = getattr(exc, "code", None)
    code = int(code) if code is not None else None
    # libcurl error codes (CURLcode).
    if code == 28 or "timed out" in text.lower():
        return Failure("network", f"Timed out after {TIMEOUT}s fetching {host}: the site is slow or drops automated clients. Try again later or use the browser tool.")
    if code in (6, 5):
        return Failure("network", f"DNS lookup failed for {host}: the host does not exist or DNS is down.")
    if code == 7:
        return Failure("network", f"Could not connect to {host} (refused or unreachable).")
    if code in (35, 51, 53, 54, 58, 59, 60, 77, 80, 83, 90, 91):
        return Failure("network", f"TLS error talking to {host}: {text}")
    if code in (52, 55, 56, 92):
        return Failure("network", f"{host} closed the connection mid-response; some sites do this to automated clients. Try the browser tool.")
    return Failure("network", f"Network error fetching {host}: {text}")


def fetch(url):
    """GET with Chrome impersonation, redirects checked hop by hop. Returns
    (final_url, status, headers, body)."""
    with requests.Session(impersonate=IMPERSONATE) as session:
        for _ in range(MAX_REDIRECTS + 1):
            check_public(url)
            try:
                response = session.get(url, allow_redirects=False, timeout=TIMEOUT, stream=True)
            except RequestException as exc:
                raise network_failure(url, exc)
            try:
                headers = {k.lower(): v for k, v in response.headers.items()}
                status = response.status_code
                location = headers.get("location")
                if status in (301, 302, 303, 307, 308) and location:
                    url = urljoin(url, location)
                    continue
                declared = headers.get("content-length", "")
                if declared.isdigit() and int(declared) > MAX_BYTES:
                    raise Failure("too_large", f"Response is {int(declared) // 1048576} MB, over the {MAX_BYTES // 1048576} MB limit; download it with the terminal (curl -o) instead.", status)
                chunks, size = [], 0
                try:
                    for chunk in response.iter_content():
                        size += len(chunk)
                        if size > MAX_BYTES:
                            raise Failure("too_large", f"Response exceeds the {MAX_BYTES // 1048576} MB limit; download it with the terminal (curl -o) instead.", status)
                        chunks.append(chunk)
                except RequestException as exc:
                    raise network_failure(url, exc)
                return url, status, headers, b"".join(chunks)
            finally:
                response.close()
    raise Failure("redirect_loop", f"More than {MAX_REDIRECTS} redirects; last target {url}.")


def status_failure(status, headers, head):
    vendor = vendor_of(headers, head)
    if status == 429:
        retry = headers.get("retry-after")
        wait = f", Retry-After {retry}" if retry else ""
        return Failure("rate_limited", f"Rate limited by the site (HTTP 429{wait}). Wait before hitting this host again, or use another source.", status)
    if status in (404, 410):
        return Failure("not_found", f"Not found (HTTP {status}). The URL is probably wrong; search for the right page instead of guessing paths.", status)
    if status == 401:
        return Failure("auth_required", "Login required (HTTP 401).", status)
    if challenge_in(head) or (status in (403, 503) and vendor):
        kind = "JS challenge" if any(m in head for m in JS_MARKERS) or "just a moment" in head else "block page"
        return Failure("blocked", f"Blocked by {vendor or 'the site'}'s bot protection (HTTP {status}, {kind}). A plain fetch cannot pass it; try the browser tool, or find the same content on another site.", status)
    if status == 403:
        return Failure("blocked", "Forbidden (HTTP 403): the site refuses automated clients or this IP. Try the browser tool, or another source.", status)
    if status >= 500:
        return Failure("http_error", f"The site failed (HTTP {status}). Try again later.", status)
    return Failure("http_error", f"HTTP {status} from the site.", status)


def decode(body, headers):
    ctype = headers.get("content-type", "")
    charset = None
    for param in ctype.split(";")[1:]:
        key, _, value = param.strip().partition("=")
        if key.lower() == "charset":
            charset = value.strip("\"' ")
    try:
        return body.decode(charset or "utf-8", errors="replace")
    except LookupError:
        return body.decode("utf-8", errors="replace")


def extract_pdf(body, url):
    import pymupdf

    try:
        doc = pymupdf.open(stream=body, filetype="pdf")
    except Exception as exc:
        raise Failure("unreadable", f"Not a readable PDF: {exc}")
    with doc:
        if doc.needs_pass:
            raise Failure("unreadable", "The PDF is password-protected.")
        pages = [page.get_text().strip() for page in doc]
        title = (doc.metadata or {}).get("title") or ""
    text = "\n\n".join(p for p in pages if p)
    if not text:
        raise Failure("unreadable", f"The PDF has {len(pages)} pages but no text layer (scanned images); there is no OCR here.")
    return title.strip() or urlsplit(url).path.rsplit("/", 1)[-1], text


def extract_html(body, url, fmt, status, headers):
    import trafilatura

    head = body[:200_000].decode("utf-8", errors="replace").lower()
    meta = trafilatura.extract_metadata(body, default_url=url)
    title = (meta.title if meta else None) or ""
    content = trafilatura.extract(
        body,
        url=url,
        output_format="markdown" if fmt == "markdown" else "txt",
        with_metadata=fmt == "markdown",
        include_links=fmt == "markdown",
        include_tables=True,
        include_comments=False,
        favor_recall=True,
    ) or ""
    if len(content) < THIN_TEXT:
        if challenge_in(head):
            raise status_failure(status, headers, head)
        if any(m in head for m in JS_MARKERS) or (not content and "<script" in head):
            raise Failure("js_required", "The page builds its content with JavaScript; the HTML holds nothing to extract. Use the browser tool.", status)
        content = content or (trafilatura.html2txt(body) or "").strip()
    if not content:
        raise Failure("empty", "The page has no extractable text.", status)
    return title, content


TEXT_TYPES = ("application/json", "application/xml", "application/rss+xml", "application/atom+xml",
              "application/javascript", "application/x-yaml", "application/ld+json")


def run(url, fmt):
    final_url, status, headers, body = fetch(url)
    head = body[:200_000].decode("utf-8", errors="replace").lower()
    if status >= 400:
        raise status_failure(status, headers, head)
    ctype = headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if ctype == "application/pdf" or body[:5] == b"%PDF-":
        title, content = extract_pdf(body, final_url)
    elif ctype in ("text/html", "application/xhtml+xml") or (not ctype and "<html" in head):
        title, content = extract_html(body, final_url, fmt, status, headers)
    elif ctype.startswith("text/") or ctype in TEXT_TYPES or ctype.endswith("+json") or ctype.endswith("+xml"):
        title, content = "", decode(body, headers)
    else:
        raise Failure("unsupported", f"Unsupported content type {ctype or 'unknown'}; download it with the terminal (curl -o) and process it there.", status)
    if final_url != url:
        content = f"(Redirected to {final_url})\n\n{content}"
    return {"url": url, "title": title, "content": content}


def main():
    url = sys.argv[1]
    fmt = sys.argv[2] if len(sys.argv) > 2 else "markdown"
    try:
        result = run(url, fmt)
    except Failure as exc:
        result = {"url": url, "error": str(exc), "kind": exc.kind, "status": exc.status}
    json.dump(result, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
