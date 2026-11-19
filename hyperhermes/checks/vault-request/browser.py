"""Drive the vault-request page the way a browser on the host does.

usage: browser.py <dashboard origin> <login> <password> <request id> <mode>

modes:
  save      sign in at dex, open the page, send a test card with a browser's
            headers; then: the same request again is refused, and a cross-site
            and a same-site post of a fresh form are refused before the page
  outsider  the account owns another agent: its sign-in at this dashboard is
            refused, the page stays behind the login
  anonymous no session: the page sends the browser to the dashboard's sign-in
  foreign   signed in at the account's own dashboard, another agent's request id
            there is unknown; the session from there, sent to the other agent's
            host (<other origin> as a 6th argument), is refused at its page
Prints one JSON line last.
"""

import html
import json
import re
import sys
import urllib.parse

import requests

origin, login, password, rid, mode, *other = sys.argv[1:]
page = f"{origin}/vault/{rid}"
TEST_CARD = "4111111111111111"
s = requests.Session()
nav = {"Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}


def sign_in():
    r = s.get(f"{origin}/auth/login", params={"provider": "self-hosted"}, headers=nav)
    r.raise_for_status()
    form = re.search(r'<form[^>]*action="([^"]*)"', r.text)
    assert form and 'name="password"' in r.text, r.text[:500]
    action = urllib.parse.urljoin(r.url, html.unescape(form.group(1)))
    return s.post(action, data={"login": login, "password": password})


def post(token, site, extra=None):
    headers = {"Sec-Fetch-Site": site, "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document",
               # the page's no-referrer policy: a browser sends Origin: null
               "Origin": "null"}
    data = {"token": token, "label": "Test card", "cardholder_name": "Test Person",
            "card_number": TEST_CARD, "exp_month": "12", "exp_year": "2099", "cvc": "123",
            **(extra or {})}
    return s.post(page, data=data, headers=headers, allow_redirects=False)


if mode == "anonymous":
    r = s.get(page, headers=nav, allow_redirects=False)
    print("anonymous:", r.status_code, r.headers.get("location"))
    assert r.status_code == 302, r.status_code
    assert r.headers["location"] == f"{origin}/auth/login?provider=self-hosted&next=/vault/{rid}", r.headers
    r = s.post(page, data={"token": "x", "card_number": TEST_CARD}, headers={"Origin": origin},
               allow_redirects=False)
    assert r.status_code == 302, r.status_code
    print(json.dumps({"anonymous": "redirected"}))
    sys.exit(0)

r = sign_in()
if mode == "outsider":
    print("sign-in:", r.status_code, r.url, r.text[:200])
    assert r.status_code == 400 and "allowed groups" in r.text, (r.status_code, r.text[:300])
    r = s.get(page, headers=nav, allow_redirects=False)
    assert r.status_code == 302 and "/auth/login" in r.headers["location"], (r.status_code, r.headers)
    print(json.dumps({"outsider": "refused"}))
    sys.exit(0)

r.raise_for_status()
assert r.url.startswith(origin), r.url
print("signed in, landed on", r.url)

if mode == "foreign":
    r = s.get(page, headers=nav)
    assert r.status_code == 404, (r.status_code, r.text[:300])
    # The account's own valid session, replayed at the other agent's host: hermes there
    # refuses the token. A token for another audience is a verification failure to hermes
    # (ProviderError, /api/auth/me answers 503), which auth_request turns into a 500; an
    # expired or unknown one is a 401, so a 302 to the sign-in. Either way: never the page.
    sessions = [c for c in s.cookies if "hermes_session_at" in c.name]
    assert sessions, sorted(c.name for c in s.cookies)
    other_page = f"{other[0]}/vault/{rid}"
    cookie = "; ".join(f"{c.name}={c.value}" for c in s.cookies)
    r = requests.get(other_page, headers={**nav, "Cookie": cookie}, allow_redirects=False)
    print("replayed session:", r.status_code, r.headers.get("location"))
    assert r.status_code in (302, 500), (r.status_code, r.headers)
    assert r.status_code == 500 or "/auth/login" in r.headers["location"], r.headers
    assert 'name="token"' not in r.text and "hermes-vault-request" not in r.headers.get("Server", ""), r.text[:300]
    print(json.dumps({"foreign": "unknown", "replayed": "refused"}))
    sys.exit(0)

# A link opened from a chat app: a cross-site navigation.
r = s.get(page, headers={**nav, "Sec-Fetch-Site": "cross-site"})
assert r.status_code == 200, (r.status_code, r.text[:300])
for header, want in (("Cache-Control", "no-store"), ("X-Frame-Options", "DENY"),
                     ("Referrer-Policy", "no-referrer")):
    assert r.headers.get(header) == want, (header, r.headers.get(header))
assert "default-src 'none'" in r.headers.get("Content-Security-Policy", ""), r.headers
assert 'autocomplete="cc-number"' in r.text and 'autocomplete="cc-csc"' in r.text, r.text
assert "https://shop.example.com" in r.text, r.text
match = re.search(r'name="token" value="([^"]+)"', r.text)
assert match, r.text
token = match.group(1)

# Cross-site and same-site posts never reach the page (exposure's gate), with or
# without the right token.
for site in ("cross-site", "same-site"):
    bad = post(token, site)
    print(site, "post:", bad.status_code, bad.text[:80])
    # exposure's gate's own answer: refused at nginx, not by the page
    assert bad.status_code == 403 and "a request from another site" in bad.text, (site, bad.status_code, bad.text[:200])
# A wrong token is refused (and counted), nothing saved.
bad = post("wrong-token", "same-origin")
assert bad.status_code == 400 and "stale" in bad.text, (bad.status_code, bad.text[:300])
assert TEST_CARD not in bad.text

ok = post(token, "same-origin")
print("save:", ok.status_code)
assert ok.status_code == 200 and "Saved." in ok.text, (ok.status_code, ok.text[:500])
assert TEST_CARD not in ok.text and TEST_CARD[-4:] not in ok.text, ok.text

again = post(token, "same-origin")
print("again:", again.status_code)
assert again.status_code == 410, (again.status_code, again.text[:300])
r = s.get(page, headers=nav)
assert r.status_code == 410, r.status_code
print(json.dumps({"saved": True, "cookies": sorted(c.name for c in s.cookies)}))
