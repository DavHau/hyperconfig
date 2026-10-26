"""Sign in to an agent's dashboard the way a browser on the host does, and
call the dashboard API with the session it gets.

usage: login.py <dashboard origin> <email> <password> <expected groups>
"""

import html
import re
import sys
import urllib.parse

import requests

origin, email, password, groups = sys.argv[1:]
s = requests.Session()

# Not signed in: the API refuses.
r = s.get(f"{origin}/api/auth/me")
assert r.status_code == 401, (r.status_code, r.text)

# hermes -> dex's authorize endpoint -> dex's password form (the only
# connector, so dex skips its connector list).
r = s.get(f"{origin}/auth/login", params={"provider": "self-hosted"})
r.raise_for_status()
form = re.search(r'<form[^>]*action="([^"]*)"', r.text)
assert form and 'name="password"' in r.text, r.text
action = urllib.parse.urljoin(r.url, html.unescape(form.group(1)))
print("dex password form:", action)

# The form -> (no approval screen) -> hermes' /auth/callback, which sets
# the session cookie and sends the browser to the dashboard.
r = s.post(action, data={"login": email, "password": password})
r.raise_for_status()
print("landed on:", r.url)
assert r.url.startswith(origin), [h.url for h in r.history] + [r.url]

me = s.get(f"{origin}/api/auth/me")
me.raise_for_status()
me = me.json()
print("session:", me)
assert me["provider"] == "self-hosted", me
assert me["email"] == email, me
# hermes joins the ID token's `groups` claim into org_id.
assert me["org_id"] == groups, me

# A gated dashboard API answers the session.
r = s.get(f"{origin}/api/config")
assert r.status_code == 200, (r.status_code, r.text[:500])
print("gated /api/config: 200")
