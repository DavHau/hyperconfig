"""Sign in to an agent's dashboard the way a browser on the host does, and
call the dashboard API with the session it gets.

usage: login.py [--refused] [--native] <dashboard origin> <email> <password> <groups>

<groups>: the dashboard's allowed group(s), which the account's session
shows. With --refused the account is outside them: dex signs it in, and the
dashboard's callback must refuse to make a session.

--native: the app's sign-in instead (RFC 8252, /auth/native/*): a PKCE
pair and a loopback redirect, the issuer asked for a fresh login
(prompt=login, which nginx adds), the one-time code redeemed at
/auth/native/token for bearer tokens, which then call the API and refresh.
Refused, the callback mints no code.

--gzip: also check nginx's compression (the dashboards module): the session
list and the sidebar slices come back gzipped, the session itself
(/api/auth/me) never does.
"""

import base64
import hashlib
import html
import re
import secrets
import sys
import urllib.parse

import requests

args = sys.argv[1:]
refused = "--refused" in args
native = "--native" in args
check_gzip = "--gzip" in args
args = [a for a in args if a not in ("--refused", "--native", "--gzip")]
origin, email, password, groups = args
s = requests.Session()

# Not signed in: the API refuses.
r = s.get(f"{origin}/api/auth/me")
assert r.status_code == 401, (r.status_code, r.text)

if native:
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    # Nothing listens there: the code is read off the redirect.
    loopback = "http://127.0.0.1:9/callback"
    start = s.get(
        f"{origin}/auth/native/authorize",
        params={
            "provider": "self-hosted",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "redirect_uri": loopback,
            "state": "app-state",
        },
        allow_redirects=False,
    )
    assert start.status_code == 302, (start.status_code, start.text[:300])
    authorize = start.headers["location"]
    print("issuer redirect:", authorize)
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(authorize).query)
    assert query.get("prompt") == ["login"], query
    r = s.get(authorize)
else:
    # hermes -> dex's authorize endpoint -> dex's password form (the only
    # connector, so dex skips its connector list).
    r = s.get(f"{origin}/auth/login", params={"provider": "self-hosted"})
r.raise_for_status()
form = re.search(r'<form[^>]*action="([^"]*)"', r.text)
assert form and 'name="password"' in r.text, r.text
action = urllib.parse.urljoin(r.url, html.unescape(form.group(1)))
print("dex password form:", action)

# The form -> (no approval screen) -> hermes' /auth/callback, which sets
# the session cookie and sends the browser to the dashboard (or, native,
# to the app's loopback redirect with a one-time code).
if native:
    r = s.post(action, data={"login": email, "password": password}, allow_redirects=False)
    while r.is_redirect and not r.headers["location"].startswith("http://127.0.0.1:9/"):
        r = s.get(urllib.parse.urljoin(r.url, r.headers["location"]), allow_redirects=False)
else:
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

if native:
    back = urllib.parse.urlsplit(r.headers.get("location", ""))
    print("app redirect:", back._replace(query="").geturl())
    assert r.status_code == 302 and back.geturl().startswith(loopback), (r.status_code, r.headers)
    got = urllib.parse.parse_qs(back.query)
    assert got["state"] == ["app-state"], got
    # No cookie on the native path: the browser holds no session.
    assert s.get(f"{origin}/api/auth/me").status_code == 401
    app = requests.Session()
    tokens = app.post(f"{origin}/auth/native/token", json={"code": got["code"][0], "code_verifier": verifier})
    assert tokens.status_code == 200, (tokens.status_code, tokens.text)
    tokens = tokens.json()
    # The code is one-time.
    again = app.post(f"{origin}/auth/native/token", json={"code": got["code"][0], "code_verifier": verifier})
    assert again.status_code == 400, (again.status_code, again.text)
    app.headers["Authorization"] = f"Bearer {tokens['access_token']}"
    refreshed = app.post(f"{origin}/auth/native/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert refreshed.status_code == 200, (refreshed.status_code, refreshed.text)
    app.headers["Authorization"] = f"Bearer {refreshed.json()['access_token']}"
    s = app
else:
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

if check_gzip:
    # requests asks for gzip itself; check the raw Content-Encoding.
    listed = s.get(f"{origin}/api/sessions?limit=50", headers={"Accept-Encoding": "gzip"})
    assert listed.status_code == 200, (listed.status_code, listed.text[:300])
    assert listed.headers.get("Content-Encoding") == "gzip", dict(listed.headers)
    assert "Accept-Encoding" in listed.headers.get("Vary", ""), dict(listed.headers)
    listed.json()
    # Another site cannot make the browser load the compressed body (BREACH),
    # not even as a top-level navigation the gate lets through elsewhere.
    for site in ("cross-site", "same-site"):
        nav = s.get(f"{origin}/api/sessions?limit=50", headers={
            "Accept-Encoding": "gzip", "Sec-Fetch-Site": site,
            "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"})
        assert nav.status_code == 403, (site, nav.status_code, nav.text[:300])
    same = s.get(f"{origin}/api/sessions?limit=50", headers={
        "Accept-Encoding": "gzip", "Sec-Fetch-Site": "same-origin",
        "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty"})
    assert same.status_code == 200 and same.headers.get("Content-Encoding") == "gzip", dict(same.headers)
    # The sidebar slices the apps re-read on every reconnect.
    sidebar = s.get(f"{origin}/api/profiles/sessions/sidebar?recents_limit=50", headers={"Accept-Encoding": "gzip"})
    assert sidebar.status_code == 200, (sidebar.status_code, sidebar.text[:300])
    assert sidebar.headers.get("Content-Encoding") == "gzip", dict(sidebar.headers)
    sidebar.json()
    me = s.get(f"{origin}/api/auth/me", headers={"Accept-Encoding": "gzip"})
    assert "Content-Encoding" not in me.headers, dict(me.headers)
    print("gzip: /api/sessions and the sidebar compressed, /api/auth/me not")
