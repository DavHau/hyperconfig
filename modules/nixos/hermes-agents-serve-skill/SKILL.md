---
name: serve-ports
description: How to publish anything you serve over HTTP (web app, preview, file server, API, dev server, notebook, report) so a person can open it at https://<port>.@HOST@/. Every account owns 5 private ports (only its owner, after login) and 5 public ports (anyone with the link). Use it every time you start a listening server that someone else should open.
---

# Publishing pages at https://<port>.@HOST@/

Nothing you listen on is reachable from outside directly. A reverse proxy
publishes your own ports, with TLS, at `https://<port>.@HOST@/`. Which port
you pick decides who can open the page:

- **private port**: the visitor logs in and only your owner's account gets
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
2. Listen on `127.0.0.1:<port>`. Not `0.0.0.0` and not `::` (nothing else
   is reachable anyway, and `::` is not protected from other local users).
   - `python3 -m http.server <port> --bind 127.0.0.1 --directory <dir>`
   - `vite --host 127.0.0.1 --port <port> --strictPort`
   - `uvicorn app:app --host 127.0.0.1 --port <port> --proxy-headers`
   - `jupyter lab --ip 127.0.0.1 --port <port> --no-browser`
3. Give the person the link `https://<port>.@HOST@/` and say whether it is
   private or public.

The page sits at the root of its own host, so apps need no base path. The
proxy sends `Host: 127.0.0.1:<port>`, `X-Forwarded-Proto: https` and
`X-Forwarded-Host: <port>.@HOST@`; apps that build absolute URLs should
trust those headers. Websockets work.

## Rules

- Only your own ports. Other agents' ports and every port outside the table
  are not published; other accounts cannot even connect to yours locally.
- Never `--port 0` / a random port for something a person should open.
- On a public port, assume the whole internet reads it. Never put secrets,
  your home directory or `/vault` there; serve a dedicated directory.
- Visitors' login cookies are removed before requests reach you; there is
  no identity header to trust. Private pages are protected by the proxy,
  not by your app.
- Stop servers you no longer need, so the port is free for the next job.
