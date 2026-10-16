---
name: web-access
description: Find, read and download things on the web from this host. Use whenever a task fetches or reads a web page or file, or a site answers 403, Cloudflare "Just a moment...", a CAPTCHA or another bot wall. Read before reaching for curl or blocked-page-recovery.
---

# Web access on this host

Three tools, in this order. Do not skip ahead, and do not fall back to the
terminal for web pages.

1. `web_search` (SearXNG on this host) to find pages.
2. `web_extract` (up to 5 URLs per call) to read a page. It fetches with
   Chrome's TLS fingerprint, keeps the main text, reads PDFs, and when the
   page is blocked or needs JavaScript it renders it once more in a
   headless anti-detect Firefox (Camoufox) by itself. Its error says why a
   page failed; act on that (see Diagnose).
3. `browser_navigate` and the other `browser_*` tools (a Camofox server:
   anti-detect Firefox) when `web_extract` reports the page blocked, and
   for interactive pages, forms and logins. A navigation waits up to ~30 s
   for a Cloudflare or Turnstile interstitial to clear and ticks its
   checkbox. Cookies persist per agent, so a check cleared once carries
   over. `browser_snapshot` with `full=true` returns the whole page text;
   `browser_vision` shows a screenshot; `browser_console` with
   `expression` evaluates JavaScript in the page.

If the first navigation answers HTTP 500 or times out, the browser was
starting cold: retry once, not more.

## Downloads

The browser tools cannot save a file. Use the browser to reach the real
file link (read its `href` from the snapshot or with `browser_console`,
e.g. `[...document.links].map(a => a.href)`), then fetch that URL with
`curl -fL -o <file> <url>` in the terminal. `web_extract` refuses files
over 25 MB and binaries; it says so, then use curl.

## Never

- Never run `curl`/`wget` with a spoofed User-Agent or browser headers
  against a Cloudflare or WAF protected site: they block on the TLS
  fingerprint, not the headers. curl is fine for APIs, raw text files and
  direct file URLs.
- Never retry a failing URL in a loop.

## Diagnose before calling a page blocked

- DNS lookup failed / unknown host / NXDOMAIN: the domain does not exist.
  Confirm with `getent hosts <domain>` (no output = gone). Say the site no
  longer exists; do not report it as blocked and do not guess hostnames.
- 404 / 410: the page is gone or the URL is wrong; search for it.
- 429: rate limit. Back off and move on; never hammer the host again in a
  loop, web.archive.org (Wayback, CDX) included.
- The site's own 403 page in the real browser ("flagged as suspicious",
  "access denied") after the challenge wait: an IP or reputation block of
  this host. Report it as that; more tries will not pass it.

## Archives come last

For a live page the order is `web_extract`, then the browser. Only when
both fail, or the page is gone, use the `blocked-page-recovery` skill for
archived copies (Wayback, archive.today). Its ladder lists the real
browser last; here you have already tried it, so skip that step.
