---
name: space-publish
description: >
  Use whenever you serve a web page, app, dashboard, notebook, preview,
  report or file listing that Dave should open in his browser. Listen on
  0.0.0.0 in the port window (8000-8099), give him
  https://<port>.<space>.davhau.fyi/ ($SPACE_PUBLIC_URL_TEMPLATE). No
  tunnels, no hostnames to guess.
---

# Showing Dave a web page from this space

Every port in the window `$SPACE_PUBLISH_PORTS` (8000-8099) that you
listen on with **0.0.0.0** (or this guest's own veth address) is
published, nothing to register:

    $SPACE_PUBLIC_URL_TEMPLATE      e.g. https://8095.<space>.davhau.fyi/

The space's name is `id -un`. Dave opens the link and signs in with
pocket-id once per port host; only the space's owners get through,
everyone else gets 403. TLS is handled; the app speaks plain HTTP.

1. Pick a free port: `space-publish` (no argument) lists what listens in
   the window.
2. Listen on 0.0.0.0:<port>:
   - `python3 -m http.server <port> --bind 0.0.0.0 --directory <dir>`
   - `vite --host 0.0.0.0 --port <port> --strictPort`
   - `uvicorn app:app --host 0.0.0.0 --port <port> --proxy-headers`
   - `jupyter lab --ip 0.0.0.0 --port <port> --no-browser`
   - most tools: `--host`/`--bind`/`HOST=0.0.0.0`
3. If the app can only bind 127.0.0.1 (e.g. a tool printing
   `http://127.0.0.1:8095`): run it on a window port and, beside it,
   `space-publish <port>` (forwards until Ctrl-C; background it with `&` or
   in a tmux window).
4. Tell Dave the URL: `https://<port>.$(id -un).davhau.fyi/`.

Do not use reverse ssh tunnels, `amy.local`, LAN IPs or ngrok-like
services: nothing but the window is reachable, and this is the way.

Details the app may care about: the proxy sends `Host: 127.0.0.1:<port>`,
`X-Forwarded-Proto: https`, `X-Forwarded-Host: <port>.<space>.davhau.fyi`;
a same-origin `Origin` arrives as `http://127.0.0.1:<port>`. Websockets
work. Paths under `/.hermes-serve-login/` belong to the login. Requests
another site's page makes the browser send (form posts, fetch, iframes)
are refused; links work.
