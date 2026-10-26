"""Open a private published port the way a browser does: the port's own
login (oauth2-proxy-serve) sends it to the issuer's password form, the
sign-in comes back to the port host's callback, and on to the page asked
for.

usage: serve.py <page url> <login> <password> <ok | forbidden | refused>

ok: the account owns the port; the page is the app's. forbidden: the
account owns another agent; signed in, but the port answers 403.
refused: the account owns no agent; the port's login refuses it (its
group check). The last line printed is JSON: the cookies the browser holds
for the port host.
"""

import html
import json
import re
import sys
import urllib.parse

import requests

url, login, password, expect = sys.argv[1:]
host = urllib.parse.urlsplit(url).hostname
s = requests.Session()

# No session: the port's login -> the issuer's password form.
r = s.get(url)
r.raise_for_status()
form = re.search(r'<form[^>]*action="([^"]*)"', r.text)
assert form and 'name="password"' in r.text, (r.url, r.text[:500])
start = [h for h in r.history if "/auth?" in h.headers.get("location", "")]
assert start, [(h.status_code, h.headers.get("location")) for h in r.history]
query = urllib.parse.parse_qs(urllib.parse.urlsplit(start[0].headers["location"]).query)
print("authorize:", query)
assert query["client_id"] == ["hermes-serve"], query
redirect_uri = query["redirect_uri"][0]
callback = urllib.parse.urlsplit(url)._replace(path="/.hermes-serve-login/callback", query="").geturl()
assert redirect_uri == callback, (redirect_uri, callback)
action = urllib.parse.urljoin(r.url, html.unescape(form.group(1)))

r = s.post(action, data={"login": login, "password": password})
if "/approval" in r.url:
    # oauth2-proxy asks for consent (its approval-prompt=force), which dex
    # then shows despite skipApprovalScreen: approve.
    fields = dict(re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)"', r.text))
    r = s.post(r.url, data={**fields, "approval": "approve"})
print("redirects:", [(h.status_code, h.url) for h in r.history], "->", r.status_code, r.url)
print("body:", r.text[:300])
jar = {c.name: c for c in s.cookies if c.domain == host}
# Over HTTPS the __Host- prefix (Secure, host-only); local HTTP keeps no
# Secure cookie.
https = url.startswith("https://")
session_name = "__Host-hermes_serve" if https else "_hermes_serve"
print("cookies:", [(c.name, c.domain, c.domain_specified, c.secure) for c in s.cookies])

if expect == "ok":
    assert r.status_code == 200 and r.url == url, (r.status_code, r.url)
    assert r.text == f"backend {host.split('.')[0]}\n", r.text
elif expect == "forbidden":
    assert r.status_code == 403 and "Not published" in r.text, (r.status_code, r.text)
elif expect == "refused":
    assert r.url.startswith(callback), r.url
    assert r.status_code == 403 and "backend" not in r.text, (r.status_code, r.text[:500])
    assert session_name not in jar, jar
else:
    sys.exit(f"unknown expectation {expect}")

if expect != "refused":
    # Host-only: no Domain attribute, so the browser keeps it to this host.
    session = jar.get(session_name)
    assert session is not None and not session.domain_specified and session.secure == https, jar
print(json.dumps({n: c.value for n, c in jar.items()}))
