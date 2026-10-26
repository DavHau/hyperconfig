"""Sign in to an agent's dashboard the way a browser on the host does, and
call the dashboard API with the session it gets.

usage: login.py [--refused] <dashboard origin> <email> <password> <groups>

<groups>: the dashboard's allowed group(s), which the account's session
shows. With --refused the account is outside them: dex signs it in, and the
dashboard's callback must refuse to make a session.
"""

import html
import re
import sys
import urllib.parse

import requests

args = sys.argv[1:]
refused = args[:1] == ["--refused"]
if refused:
    args = args[1:]
origin, email, password, groups = args
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
if refused:
    # dex accepted the password and sent the browser back with a code; the
    # callback verifies the ID token and refuses its groups.
    print("callback answered:", r.status_code, r.url, r.text[:300])
    assert r.url.startswith(f"{origin}/auth/callback"), [h.url for h in r.history] + [r.url]
    assert r.status_code == 400 and "allowed groups" in r.text, (r.status_code, r.text)
    me = s.get(f"{origin}/api/auth/me")
    assert me.status_code == 401, (me.status_code, me.text)
    r = s.get(f"{origin}/api/config")
    assert r.status_code == 401, (r.status_code, r.text[:500])
    print("refused: no session")
    sys.exit(0)
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
