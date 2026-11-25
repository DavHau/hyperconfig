"""Drive the owner's vault page (modules/vault-request/owner.nix) the way a browser on the host does.

usage: owner.py <front door origin> <dashboard origin> <agent> <login> <password> <mode> [<login id>]

modes:
  anonymous  no session: the dashboard's /vault and /vault/ send the browser to the page, the page
             to the front door's sign-in; a POST gets the same, nothing of the vault
  outsider   signed in at the front door with an account that does not own the agent: 403, also
             for a POST
  owner      signed in as an owner: the list (a card's brand and last 4 only, the login's name),
             a cross-site and a same-site POST refused at nginx, a wrong form token refused, the
             login's password revealed (no-store, only in that response), a card's refused, then
             the login deleted after a confirmation
Prints one JSON line last.
"""

import hashlib
import html
import json
import re
import sys
import urllib.parse

import requests

front, dashboard, agent, login, password, mode, *rest = sys.argv[1:]
page = f"{front}/vault/{agent}/"
CARD = "4111111111111111"
s = requests.Session()
nav = {"Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}


def post(data, site="same-origin", session=s):
    headers = {"Sec-Fetch-Site": site, "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document",
               "Origin": "null"}
    return session.post(page, data=data, headers=headers, allow_redirects=False)


# Without a session: the dashboard's address -> the page -> the front door's sign-in.
for path in ("/vault", "/vault/"):
    r = requests.get(f"{dashboard}{path}", headers=nav, allow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == page, (path, r.status_code, r.headers)

if mode == "anonymous":
    r = s.get(page, headers=nav, allow_redirects=False)
    print("anonymous:", r.status_code, r.headers.get("location"))
    assert r.status_code == 302, r.status_code
    assert r.headers["location"].startswith(f"{front}/oauth2/start?rd=/vault/{agent}/"), r.headers
    r = s.post(page, data={"action": "reveal"}, allow_redirects=False)
    assert r.status_code == 302 and "/oauth2/start" in r.headers["location"], (r.status_code, r.headers)
    print(json.dumps({"anonymous": "redirected"}))
    sys.exit(0)

# Sign in at the front door (oauth2-proxy -> the issuer's password form), from the page itself.
r = s.get(page, headers=nav)
form = re.search(r'<form[^>]*action="([^"]*)"', r.text)
assert form and 'name="password"' in r.text, (r.url, r.text[:500])
r = s.post(urllib.parse.urljoin(r.url, html.unescape(form.group(1))), data={"login": login, "password": password})
if "/approval" in r.url:
    fields = dict(re.findall(r'<input type="hidden" name="([^"]+)" value="([^"]*)"', r.text))
    r = s.post(r.url, data={**fields, "approval": "approve"})
print("after sign-in:", r.status_code, r.url)
assert r.url == page, r.url

if mode == "outsider":
    assert r.status_code == 403 and "does not own" in r.text, (r.status_code, r.text[:300])
    bad = post({"token": "x" * 64, "store": "home", "item_id": rest[0] if rest else "vault_0", "action": "reveal"})
    assert bad.status_code == 403 and "does not own" in bad.text, (bad.status_code, bad.text[:300])
    print(json.dumps({"outsider": "refused"}))
    sys.exit(0)

assert r.status_code == 200, (r.status_code, r.text[:500])
for header, want in (("Cache-Control", "no-store"), ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer")):
    assert r.headers.get(header) == want, (header, r.headers.get(header))
assert "default-src 'none'" in r.headers["Content-Security-Policy"], r.headers
listing = r.text
assert "Test card" in listing and "Visa &bull;&bull;&bull;&bull; 1111" in listing, listing
assert CARD not in listing and "411111" not in listing, listing
assert "Shop account" in listing and "alice@shop.example.com" in listing, listing
login_id = rest[0]
token = re.search(r'name="token" value="([0-9a-f]+)"', listing).group(1)
assert "Gen3rated" not in listing, listing
card_id = re.search(r'name="item_id" value="(vault_[0-9a-f]+)"[^<]*<input type="hidden" name="action" value="delete">',
                    listing.split("Test card", 1)[1]).group(1)

reveal = {"token": token, "store": "home", "item_id": login_id, "action": "reveal"}
for site in ("cross-site", "same-site"):
    bad = post(reveal, site)
    assert bad.status_code == 403 and "a request from another site" in bad.text, (site, bad.status_code, bad.text[:200])
    assert "Gen3rated" not in bad.text
bad = post({**reveal, "token": "0" * 64})
assert bad.status_code == 403 and "stale" in bad.text and "Gen3rated" not in bad.text, (bad.status_code, bad.text[:300])
# another session without the owner's login cannot use the owner's form token
other = requests.Session()
bad = post(reveal, session=other)
assert bad.status_code == 302 and "/oauth2/start" in bad.headers["location"], (bad.status_code, bad.headers)

shown = post(reveal)
print("reveal:", shown.status_code)
assert shown.status_code == 200, (shown.status_code, shown.text[:500])
assert shown.headers.get("Cache-Control") == "no-store", shown.headers
assert "script-src 'nonce-" in shown.headers["Content-Security-Policy"], shown.headers
assert 'value="Gen3rated-Pa55word-x9"' in shown.text and 'value="alice@shop.example.com"' in shown.text, shown.text
assert 'data-copy="password"' in shown.text, shown.text

card = post({**reveal, "item_id": card_id})
assert card.status_code == 400 and "last 4" in card.text and CARD not in card.text, (card.status_code, card.text[:300])

delete = {"token": token, "store": "home", "item_id": login_id, "action": "delete"}
confirm = post(delete)
assert confirm.status_code == 200 and "cannot be undone" in confirm.text and 'name="confirm" value="yes"' in confirm.text, confirm.text
r = s.get(page, headers=nav)
assert "Shop account" in r.text, "deleted without confirmation"
done = post({**delete, "confirm": "yes"})
assert done.status_code == 200 and "Deleted." in done.text, (done.status_code, done.text[:300])
r = s.get(page, headers=nav)
assert "Shop account" not in r.text and "Test card" in r.text, r.text
print(json.dumps({"owner": "ok", "revealed": hashlib.sha256(b"Gen3rated-Pa55word-x9").hexdigest()[:8],
                  "card": card_id}))
