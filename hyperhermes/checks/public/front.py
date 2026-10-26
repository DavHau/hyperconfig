"""Sign in at the front door (oauth2-proxy) the way a browser does, then
ask it where to go.

usage: front.py <front door origin> <email> <password> <dashboard origin | ->

With a dashboard origin the account owns exactly that agent: / answers 302
there and /app lists it. With `-` the account owns none: both answer 403.
"""

import html
import re
import sys
import urllib.parse

import requests

origin, email, password, dashboard = sys.argv[1:]
s = requests.Session()

# Not signed in: oauth2-proxy -> the issuer's password form.
r = s.get(f"{origin}/")
r.raise_for_status()
form = re.search(r'<form[^>]*action="([^"]*)"', r.text)
assert form and 'name="password"' in r.text, (r.url, r.text[:500])
action = urllib.parse.urljoin(r.url, html.unescape(form.group(1)))

# The form -> oauth2-proxy's callback (sets the cookie) -> back to /,
# the front door's own answer (and wherever that leads).
r = s.post(action, data={"login": email, "password": password})
if "/approval" in r.url:
    # oauth2-proxy asks for consent (its approval-prompt=force), which dex
    # then shows despite skipApprovalScreen: approve.
    fields = dict(re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)"', r.text))
    r = s.post(r.url, data={**fields, "approval": "approve"})
print("redirects:", [(h.status_code, h.url) for h in r.history], "->", r.status_code, r.url)
print("cookies:", [(c.name, c.domain, c.secure) for c in s.cookies])
assert any(c.name == "__Host-hermes" and c.secure and c.domain == urllib.parse.urlsplit(origin).hostname for c in s.cookies), s.cookies

r = s.get(f"{origin}/", allow_redirects=False)
print("front door /:", r.status_code, r.headers.get("location"), r.text[:200])
app = s.get(f"{origin}/app", allow_redirects=False)
print("front door /app:", app.status_code)
if dashboard == "-":
    assert r.status_code == 403, (r.status_code, r.text)
    assert app.status_code == 403, (app.status_code, app.text)
else:
    assert r.status_code == 302 and r.headers["location"] == f"{dashboard}/", (r.status_code, r.headers)
    assert app.status_code == 200 and dashboard in app.text, (app.status_code, app.text[:500])
