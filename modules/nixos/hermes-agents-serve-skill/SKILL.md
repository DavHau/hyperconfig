---
name: serve-ports
description: How to publish anything you serve over HTTP (web app, preview, file server, API, dev server, notebook, report) so a person can open it at https://<port>.<your account>.@DOMAIN@/. Every account owns 5 private ports (only its owner, after login) and 5 public ports (anyone with the link). Use it every time you start a listening server that someone else should open.
---

# Publishing pages at https://<port>.<account>.@DOMAIN@/

Nothing you listen on is reachable from outside directly. A reverse proxy
publishes your own ports, with TLS, at `https://<port>.<account>.@DOMAIN@/`
(your account name, then the port). Which port you pick decides who can
open the page:

- **private port**: the visitor logs in (once per port; after the first
  login it is usually automatic) and only your owner's account gets
  through; everyone else gets 403. Use this by default.
- **public port**: anyone with the link can open it, no login. Use it only
  when your owner asks you to share something publicly.

Your account name is `id -un`. Your ports:

| account | private ports | public ports |
| --- | --- | --- |
@PORTS@

## How to serve

1. Pick a free port of the right kind from your row. Check which are taken:
   `ss -ltn 'sport >= :<first> and sport <= :<last>'`.
2. Listen on IPv4 `127.0.0.1:<port>`. Not `::` or dual-stack (the proxy
   checks that the listener is yours in the kernel's IPv4 table and
   answers 502 for one on `::`), not `::1`, and not `localhost` (many
   servers, vite and node among them, bind that to `::1` only): both give
   502. Not `0.0.0.0` either: nothing else is reachable anyway.
   - `python3 -m http.server <port> --bind 127.0.0.1 --directory <dir>`
   - `vite --host 127.0.0.1 --port <port> --strictPort`
   - `uvicorn app:app --host 127.0.0.1 --port <port> --proxy-headers`
   - `jupyter lab --ip 127.0.0.1 --port <port> --no-browser`
3. Give the person the link `https://<port>.<account>.@DOMAIN@/` and say
   whether it is private or public.

The page sits at the root of its own host, so apps need no base path. The
proxy sends `Host: 127.0.0.1:<port>`, `X-Forwarded-Proto: https` and
`X-Forwarded-Host: <port>.<account>.@DOMAIN@`; apps that build absolute URLs
should trust those headers. Websockets work. A browser's `Origin` from the
page itself arrives as `http://127.0.0.1:<port>`, matching that Host, so an
app's own same-origin check passes; other origins arrive unchanged.

## Rules

- Only your own ports, under your own name: a port under another account's
  name, and every port outside the table, is not published; other accounts
  cannot even connect to yours locally.
- The paths below `/.hermes-serve-login/` belong to the login of private
  ports; your app never sees them there.
- Private ports refuse what a page of any other origin (another port,
  another agent, any other site) makes the visitor's browser send there:
  form posts, fetch, websockets, iframes. Links to them still work, and the
  port's own pages are not affected.
- Never `--port 0` / a random port for something a person should open.
- Each visitor's network gets at most 128 requests in flight and 50 a
  second (after a burst of 500, enough for a dev server's page load) per
  port; beyond that the proxy answers 429.
- On a public port, assume the whole internet reads it. Never put secrets,
  your home directory or `/vault` there; serve a dedicated directory.
- Only cookies whose name starts with a letter or digit (and jupyter's
  `_xsrf`) reach your app; name your own cookies that way. Every other
  cookie is dropped before your app sees it: names starting with `_` (the
  visitors' login, but also app defaults such as Streamlit's
  `_streamlit_xsrf`, Rails' `_<app>_session`, Gitea's `_csrf`) and the
  `__Host-` / `__Secure-` prefixed ones (`__Secure-next-auth.session-token`).
  An app that relies on such a cookie loops on login or answers 403; rename
  the cookie in the app's settings.
  There is no identity header to trust. Private pages are protected by the
  proxy, not by your app.
- Stop servers you no longer need, so the port is free for the next job.
