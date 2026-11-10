"""clan-secret-prompt: ask Dave for a clan var's value on a web page, never in chat.

The agent (user infra in the infra-space guest) runs

    clan-secret-prompt [--flake DIR] <machine> <generator> [<file>]

which creates a one-time request and prints only its URL (the dashboard's
origin, /secret/<id>). Dave opens it (behind the dashboard's OIDC login, the
host's nginx checks it), sees which machine/generator/file it is for, the
prompt's description and whether a value is set already, and types the value
(masked, twice). This service (same user, it needs the TPM age key) then runs
the synced `clan` wrapper with the value on stdin:

    with <file>:    clan vars set <machine> <generator>/<file>
    without <file>: clan vars set ... for each of the generator's prompts
                    (all persisted, secret), then
                    clan vars generate <machine> --generator <generator>

The agent waits with `clan-secret-prompt --wait <id>` and gets one line:
`set`, `expired`, `cancelled` or `error: <reason>`: never the value and
never clan's output (`error: clan vars set failed (exit N)`); that goes to
Dave's page only, scrubbed of the value where found, and to no log.

Right before clan runs, the generator's definition and the flake's content
(its narHash) are evaluated again; any change since the request refuses
the submission (the page shows what changed). A generator asked as a whole
(generate mode) must not exist yet, at the request and at the submission:
regenerating one needs Dave at a terminal (`clan vars generate
--regenerate`). Every state change of a request happens under a flock on
its lock file (service and --cancel alike); a failure or timeout always
ends in `error` (clan runs in its own process group, killed whole on a
timeout, so no clan keeps the store's lock).

The value travels only in the POST body to this service and on to clan's
stdin: never in argv, the environment, a file of ours, a log line or the
agent's output. Requests: one JSON file each in the runtime directory
(0700, files 0600), id = 128 random bits, a separate form token (CSRF),
bound to exactly that machine/generator/file(s), expiring, single use.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hmac
import html
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import NoReturn

# Set by the Nix wrapper (./default.nix).
STATE_DIR = Path(os.environ.get("CLAN_SECRET_PROMPT_DIR", "/run/clan-secret-prompt"))
PUBLIC_URL = os.environ.get("CLAN_SECRET_PROMPT_URL", "").rstrip("/")
CLAN = os.environ.get("CLAN_SECRET_PROMPT_CLAN", "clan")
STORE = Path(os.environ.get("CLAN_SECRET_PROMPT_STORE", str(Path.home() / "clan-secrets")))
DEFAULT_FLAKE = os.environ.get("CLAN_SECRET_PROMPT_FLAKE", str(Path.home() / "hyperconfig"))
# at most 15 minutes; shorter for tests
TTL = max(1, min(900, int(os.environ.get("CLAN_SECRET_PROMPT_TTL", "900"))))
MAX_PENDING = 10
MAX_ATTEMPTS = 5
# The service's own limits; nginx takes 1 MiB of body and buffers it in
# memory whole (../dashboard.nix: never to a temp file).
MAX_VALUE = 256 * 1024
MAX_BODY = 1024 * 1024
MAX_REASON = 300
CLAN_TIMEOUT = int(os.environ.get("CLAN_SECRET_PROMPT_CLAN_TIMEOUT", "1800"))
# the host's veth address: the only client (unset: any, for tests)
PEER = os.environ.get("CLAN_SECRET_PROMPT_PEER", "")
ID_RE = re.compile(r"^[0-9a-f]{32}$")
# no dots: the names become a nix attribute path
NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,127}$")


def _die(msg: str, code: int = 1) -> NoReturn:
    print(f"clan-secret-prompt: {msg}", file=sys.stderr)
    sys.exit(code)


# --- request files -------------------------------------------------------
#
# Every state transition (pending -> running/cancelled/error, running ->
# set/error, attempts) happens under an exclusive flock on the request's
# own lock file, in the CLI (--cancel) and in the service alike, so a
# cancel and a submission never both win. Readers (--wait, the page) need
# no lock: a request file is replaced atomically.

def _path(rid: str) -> Path:
    if not ID_RE.match(rid):
        raise ValueError("bad id")
    return STATE_DIR / f"{rid}.json"


@contextlib.contextmanager
def _locked(rid: str):
    fd = os.open(_path(rid).with_suffix(".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # releases the lock


def _load(rid: str) -> dict | None:
    try:
        with open(_path(rid), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _save(req: dict) -> None:
    path = _path(req["id"])
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(req, f)
    os.replace(tmp, path)


def _effective_state(req: dict) -> str:
    if req["state"] == "pending" and time.time() > req["expires"]:
        return "expired"
    # the service died while storing it (it sets error itself otherwise)
    if req["state"] == "running" and time.time() > req["expires"] + CLAN_TIMEOUT + 600:
        return "error"
    return req["state"]


def _prune() -> None:
    """Drop requests a day past their expiry (and their lock files)."""
    for p in STATE_DIR.glob("*.json"):
        try:
            req = json.loads(p.read_text())
            if time.time() > req["expires"] + 86400:
                p.unlink()
                p.with_suffix(".lock").unlink(missing_ok=True)
        except (OSError, ValueError, KeyError):
            pass


# --- the flake's view of the generator ----------------------------------

_APPLY = """g: {
  share = g.share or false;
  files = builtins.mapAttrs (n: f: { secret = f.secret or true; deploy = f.deploy or true; }) (g.files or { });
  prompts = builtins.mapAttrs (n: p: {
    description = p.description or n;
    type = p.type or "line";
    persist = p.persist or false;
  }) (g.prompts or { });
}"""


class Refused(Exception):
    """A request the flake or the store does not (or no longer) allow."""


def _run(cmd: list[str], timeout: int = 600) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)


def _eval_generator(flake: str, machine: str, generator: str) -> dict:
    # names are [A-Za-z0-9_-] only (NAME_RE): no dot can nest the path
    attr = f"{flake}#nixosConfigurations.{machine}.config.clan.core.vars.generators.{generator}"
    r = _run(["nix", "eval", "--json", attr, "--apply", _APPLY])
    if r.returncode != 0:
        last = (r.stderr.strip().splitlines() or ["nix eval failed"])[-1]
        raise Refused(f"no generator {generator!r} on machine {machine!r} in {flake}: {last}")
    return json.loads(r.stdout)


def _flake_state(flake: str) -> dict:
    """What the page shows about the flake, and its content's hash: any
    change of the flake's files between the request and the submission
    changes `nar_hash`."""
    r = _run(["nix", "flake", "metadata", "--json", flake])
    if r.returncode != 0:
        raise Refused(f"cannot read the flake {flake}")
    meta = json.loads(r.stdout)
    nar_hash = (meta.get("locked") or {}).get("narHash") or meta.get("path") or ""

    def git(*args: str) -> subprocess.CompletedProcess:
        return _run(["git", "-C", flake, *args])
    head = git("rev-parse", "--short=12", "HEAD")
    if head.returncode != 0:
        text = "not a git checkout"
    else:
        on_main = git("merge-base", "--is-ancestor", "HEAD", "refs/remotes/origin/main").returncode == 0
        dirty = bool(git("status", "--porcelain", "--untracked-files=no").stdout.strip())
        text = (f"commit {head.stdout.strip()}, {'on' if on_main else 'NOT on'} origin/main"
                f"{', with uncommitted changes' if dirty else ''}")
    return {"text": text, "nar_hash": nar_hash}


def _store_dir(share: bool, machine: str, generator: str) -> Path:
    base = STORE / "clan-vars" / ("shared" if share else f"per-machine/{machine}")
    return base / generator


def _var_is_set(share: bool, machine: str, generator: str, file: str) -> bool:
    return (_store_dir(share, machine, generator) / file / f"{file}.age").exists()


def _generator_exists(share: bool, machine: str, generator: str) -> bool:
    d = _store_dir(share, machine, generator)
    return d.is_dir() and any(d.iterdir())


_REGENERATE = ("regenerating an existing generator needs Dave at a terminal: "
               "`clan vars generate {m} --generator {g} --regenerate`")


def _plan(flake: str, machine: str, generator: str, file: str | None) -> dict:
    """The request's binding: what the flake says now. Raises Refused."""
    gen = _eval_generator(flake, machine, generator)
    files, prompts = gen["files"], gen["prompts"]
    if file:
        f = files.get(file)
        if f is None:
            raise Refused(f"generator {generator!r} has no file {file!r} (files: {', '.join(sorted(files)) or 'none'})")
        if not f["secret"]:
            raise Refused(f"{generator}/{file} is a public var; only secret vars are set this way")
        p = prompts.get(file)
        fields = [{"name": file,
                   "description": p["description"] if p else f"value of {generator}/{file}",
                   "type": p["type"] if p else "hidden"}]
        mode = "set"
    else:
        if not prompts:
            raise Refused(f"generator {generator!r} has no prompts; name the file to set")
        for name, p in prompts.items():
            f = files.get(name)
            if not p["persist"] or f is None or not f["secret"]:
                raise Refused(f"prompt {name!r} of {generator!r} is not persisted as a secret file; "
                              "ask Dave to run `clan vars generate` himself")
        public = [n for n, f in files.items() if not f["secret"]]
        if public:
            raise Refused(f"generator {generator!r} has public files ({', '.join(public)}), which clan "
                          "writes into the flake checkout; ask Dave to run `clan vars generate` himself")
        # Without --regenerate clan runs a generator only if it is missing
        # (and --regenerate prompts on a TTY): an existing one would get
        # its prompts replaced while its other files stay stale.
        if _generator_exists(gen["share"], machine, generator):
            raise Refused(f"generator {generator!r} of {machine!r} exists already; "
                          + _REGENERATE.format(m=machine, g=generator))
        fields = [{"name": n, "description": p["description"], "type": p["type"]}
                  for n, p in sorted(prompts.items())]
        mode = "generate"
    return {"generator_def": gen, "share": gen["share"], "mode": mode, "fields": fields,
            "flake_state": _flake_state(flake)}


def _recheck(req: dict) -> list[str]:
    """What changed since the request (empty: nothing). Run right before clan."""
    try:
        now = _plan(req["flake"], req["machine"], req["generator"], req["file"])
    except Refused as e:
        return [str(e)]
    changes = []
    for key, what in (("generator_def", "the generator's definition"), ("mode", "the action"),
                      ("fields", "the fields")):
        old = req[key]
        if key == "fields":  # minus what the page says about the store
            old = [{k: v for k, v in f.items() if k != "set"} for f in old]
        if now[key] != old:
            changes.append(f"{what}: {json.dumps(old, sort_keys=True)} -> {json.dumps(now[key], sort_keys=True)}")
    if now["flake_state"] != req["flake_state"]:
        changes.append(f"the flake: {req['flake_state']['text']} ({req['flake_state']['nar_hash']}) -> "
                       f"{now['flake_state']['text']} ({now['flake_state']['nar_hash']})")
    return changes


# --- the agent's side ----------------------------------------------------

def cmd_request(args: argparse.Namespace) -> None:
    if not PUBLIC_URL:
        _die("no public URL configured (the dashboard is not published here)")
    for what, v in (("machine", args.machine), ("generator", args.generator)) + (
            (("file", args.file),) if args.file else ()):
        if not NAME_RE.match(v):
            _die(f"invalid {what} name {v!r} (only A-Z a-z 0-9 _ -)")
    reason = " ".join((args.reason or "").split())
    if len(reason) > MAX_REASON:
        _die(f"--reason is longer than {MAX_REASON} characters")
    flake = str(Path(args.flake).resolve())
    try:
        plan = _plan(flake, args.machine, args.generator, args.file)
    except Refused as e:
        _die(str(e))
    for fl in plan["fields"]:
        fl["set"] = _var_is_set(plan["share"], args.machine, args.generator, fl["name"])

    STATE_DIR.mkdir(mode=0o700, exist_ok=True)
    _prune()
    pending = 0
    for p in STATE_DIR.glob("*.json"):
        try:
            if _effective_state(json.loads(p.read_text())) == "pending":
                pending += 1
        except (OSError, ValueError, KeyError):
            pass
    if pending >= MAX_PENDING:
        _die(f"{pending} requests are pending already; wait for them or cancel some")
    now = time.time()
    req = {
        "id": secrets.token_hex(16),
        "token": secrets.token_urlsafe(32),
        "machine": args.machine,
        "generator": args.generator,
        "file": args.file,
        "flake": flake,
        **plan,
        "reason": reason,
        "created": now,
        "expires": now + TTL,
        "state": "pending",
        "error": "",
        "attempts": 0,
    }
    _save(req)
    print(f"{PUBLIC_URL}/secret/{req['id']}")
    print(f"(expires in {TTL // 60} min; then: clan-secret-prompt --wait {req['id']})", file=sys.stderr)


def cmd_wait(args: argparse.Namespace) -> None:
    if not ID_RE.match(args.wait):
        _die("invalid request id", 2)
    deadline = time.time() + args.timeout if args.timeout else None
    while True:
        req = _load(args.wait)
        if req is None:
            _die("no such request", 2)
        state = _effective_state(req)
        if state not in ("pending", "running") or (deadline and time.time() > deadline):
            break
        time.sleep(2)
    if state == "error":
        print(f"error: {req['error'] or 'the service stopped while storing it'}")
        sys.exit(1)
    print(state)
    sys.exit(0 if state == "set" else 1)


def cmd_cancel(args: argparse.Namespace) -> None:
    if not ID_RE.match(args.cancel):
        _die("invalid request id", 2)
    if _load(args.cancel) is None:
        _die("no such request", 2)
    with _locked(args.cancel):
        req = _load(args.cancel)
        if _effective_state(req) == "pending":
            req["state"] = "cancelled"
            _save(req)
    print(_effective_state(req))


# --- Dave's side: the web service -----------------------------------------

_LOCK = threading.Lock()  # one submission at a time; clan's wrapper also locks the store
_CSP = ("default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; "
        "frame-ancestors 'none'; base-uri 'none'")


def _page(title: str, body: str) -> bytes:
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<meta name="referrer" content="no-referrer"><title>{html.escape(title)}</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:46em;margin:2em auto;padding:0 1em;line-height:1.4}}
.target{{border:3px solid #b45309;background:#fffbeb;padding:1em;border-radius:6px}}
.target code{{font-size:1.15em;font-weight:bold}}
table{{border-collapse:collapse}} td{{padding:.2em .8em .2em 0;vertical-align:top}}
label{{display:block;margin-top:1em;font-weight:bold}}
input[type=password],textarea{{width:100%;font-family:monospace;padding:.4em;box-sizing:border-box}}
textarea{{-webkit-text-security:disc;text-security:disc;height:6em}}
pre{{white-space:pre-wrap;background:#f3f4f6;padding:.6em;max-height:30em;overflow:auto}}
.warn{{color:#b91c1c}} .ok{{color:#15803d}} .note{{color:#4b5563;font-size:.9em}}
button{{margin-top:1.2em;padding:.5em 1.5em;font-size:1em}}
</style></head><body>{body}</body></html>""".encode()


def _target_html(req: dict) -> str:
    e = html.escape
    rows = [
        ("Machine", f"<code>{e(req['machine'])}</code>" + (" (shared var: every machine that has this generator)" if req["share"] else "")),
        ("Generator", f"<code>{e(req['generator'])}</code>"),
        ("Action", "clan vars set " + ", ".join(f"<code>{e(req['generator'])}/{e(f['name'])}</code>" for f in req["fields"])
         + (f", then <code>clan vars generate {e(req['machine'])} --generator {e(req['generator'])}</code>" if req["mode"] == "generate" else "")),
        ("Flake", f"<code>{e(req['flake'])}</code> ({e(req['flake_state']['text'])}); checked again before storing"),
        ("Expires", time.strftime("%H:%M:%S %Z", time.localtime(req["expires"]))),
    ]
    if req.get("reason"):
        rows.append(("Agent's reason", f"<i>{e(req['reason'])}</i> (written by the agent, not verified)"))
    return ('<div class="target"><table>' + "".join(f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in rows)
            + "</table></div>")


def _form_html(req: dict, error: str = "") -> bytes:
    e = html.escape
    parts = [f"<h1>Secret for <code>{e(req['machine'])}</code>: <code>{e(req['generator'])}</code></h1>",
             "<p>The infra agent asks you for this value. It goes straight into the clan vars store "
             "(encrypted); the agent only learns whether it was set. Only enter it if you expected "
             "this request.</p>", _target_html(req),
             '<p class="note">Submitting needs a valid dashboard session: if this page has been open '
             "long, reload it before typing (an expired session sends you to the sign-in and the "
             "typed value is dropped, never stored).</p>"]
    if error:
        parts.append(f'<p class="warn"><b>{e(error)}</b></p>')
    parts.append(f'<form method="post" autocomplete="off"><input type="hidden" name="token" value="{e(req["token"])}">')
    for i, f in enumerate(req["fields"]):
        status = ('<span class="warn">a value is set already: submitting replaces it</span>' if f["set"]
                  else '<span class="ok">not set yet</span>')
        multi = f["type"].startswith("multiline")
        parts.append(f"<fieldset><legend><code>{e(req['generator'])}/{e(f['name'])}</code> ({status})</legend>"
                     f"<p>{e(f['description'])} <span class=\"note\">(description from the flake, not verified)</span></p>")
        if multi:
            parts.append('<p class="note">Multi-line field: masked only in browsers that support '
                         "<code>-webkit-text-security</code> on text areas; elsewhere the value is "
                         "visible while you type.</p>")
        for suffix, label in (("", "Value"), ("_confirm", "Confirm")):
            name = f"v{i}{suffix}"
            parts.append(f'<label for="{name}">{label}</label>')
            if multi:
                parts.append(f'<textarea id="{name}" name="{name}" required spellcheck="false" autocomplete="off"></textarea>')
            else:
                parts.append(f'<input type="password" id="{name}" name="{name}" required autocomplete="new-password">')
        parts.append("</fieldset>")
    parts.append("<button type=\"submit\">Store in clan vars</button></form>")
    return _page(f"clan secret: {req['machine']} {req['generator']}", "".join(parts))


def _scrub(text: str, values: list[str]) -> str:
    """Best effort only: clan's output goes to Dave's page, never to the
    agent or a log."""
    pieces = set()
    for v in values:
        for form in (v, v.strip(), repr(v)[1:-1], json.dumps(v)[1:-1], urllib.parse.quote(v),
                     urllib.parse.quote_plus(v)):
            pieces.add(form)
        pieces.update(line.strip() for line in v.splitlines())
    for piece in sorted((p for p in pieces if len(p) >= 4), key=len, reverse=True):
        text = text.replace(piece, "<redacted>")
    return text


def _kill_group(proc: subprocess.Popen) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=10)
            return
        except subprocess.TimeoutExpired:
            pass


def _run_clan(args: list[str], stdin: bytes | None) -> tuple[int, bytes]:
    """clan's exit status and its output (for Dave's page only). In its own
    process group: on a timeout the whole of it goes, so nothing keeps the
    store's lock."""
    proc = subprocess.Popen([CLAN, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = proc.communicate(stdin if stdin is not None else b"", timeout=CLAN_TIMEOUT)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        return -1, f"timed out after {CLAN_TIMEOUT} s; clan's process group was killed".encode()
    except BaseException:
        _kill_group(proc)
        raise
    return proc.returncode, out


class ClanFailed(Exception):
    def __init__(self, agent_msg: str, detail: str):
        super().__init__(agent_msg)
        self.agent_msg, self.detail = agent_msg, detail


def _apply(req: dict, values: list[str]) -> None:
    flake = ["--flake", req["flake"]]
    steps = [(["vars", "set", *flake, req["machine"], f"{req['generator']}/{f['name']}"], v.encode(), "vars set")
             for f, v in zip(req["fields"], values)]
    if req["mode"] == "generate":
        steps.append((["vars", "generate", *flake, req["machine"], "--generator", req["generator"]], None, "vars generate"))
    for argv, stdin, what in steps:
        rc, out = _run_clan(argv, stdin)
        if rc != 0:
            lines = out.decode(errors="replace").strip().splitlines()[-30:]
            raise ClanFailed(f"clan {what} timed out" if rc == -1 else f"clan {what} failed (exit {rc})",
                             f"clan {' '.join(argv[:2])} ... (exit {rc}):\n" + _scrub("\n".join(lines), values)[-6000:])


class Handler(BaseHTTPRequestHandler):
    server_version = "clan-secret-prompt"
    sys_version = ""

    def log_message(self, format, *args):  # nothing: nginx logs the requests
        pass

    def _send(self, code: int, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", _CSP)
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _gone(self, state: str) -> None:
        msg = {"set": "This request was answered already: the value is stored.",
               "expired": "This request has expired. Ask the agent for a new one.",
               "cancelled": "The agent cancelled this request.",
               "running": "This request is being stored right now.",
               "error": "This request failed; ask the agent for a new one."}.get(state, "Unknown request.")
        self._send(410 if state != "missing" else 404, _page("clan secret", f"<p>{html.escape(msg)}</p>"))

    def _peer_ok(self) -> bool:
        # only the host's nginx (the veth peer); the guest's own users are
        # also kept off by the guest's output gate (./default.nix)
        if PEER and self.client_address[0] != PEER:
            self._send(403, _page("clan secret", "<p>Forbidden.</p>"))
            return False
        return True

    def _rid(self) -> str | None:
        m = re.fullmatch(r"/secret/([0-9a-f]{32})", self.path)
        if not m or _load(m.group(1)) is None:
            self._gone("missing")
            return None
        return m.group(1)

    def _pending(self, rid: str) -> dict | None:
        req = _load(rid)
        state = _effective_state(req)
        if state != "pending":
            self._gone(state)
            return None
        return req

    def do_GET(self):
        if not self._peer_ok():
            return
        rid = self._rid()
        if rid is None:
            return
        req = self._pending(rid)
        if req is not None:
            self._send(200, _form_html(req))

    def do_POST(self):
        if not self._peer_ok():
            return
        # Same-origin only (the session cookie is SameSite=Lax; this is belt and braces).
        site = self.headers.get("Sec-Fetch-Site")
        origin = self.headers.get("Origin")
        if (site and site not in ("same-origin", "none")) or (origin and PUBLIC_URL and origin != PUBLIC_URL):
            self._send(403, _page("clan secret", "<p>Cross-origin submission refused.</p>"))
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self._send(413, _page("clan secret", "<p>Too large.</p>"))
            return
        body = self.rfile.read(length)
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/x-www-form-urlencoded":
            self._send(415, _page("clan secret", "<p>Unsupported form encoding.</p>"))
            return
        rid = self._rid()
        if rid is None:
            return
        with _LOCK:
            self._submit(rid, body)

    def _submit(self, rid: str, body: bytes) -> None:
        # pending -> running, under the request's lock (as --cancel)
        with _locked(rid):
            req = self._pending(rid)
            if req is None:
                return
            try:
                form = urllib.parse.parse_qs(body.decode("utf-8"), keep_blank_values=True, strict_parsing=False)
            except UnicodeDecodeError:
                form = {}
            token = (form.get("token") or [""])[0]
            if not hmac.compare_digest(token.encode(), req["token"].encode()):
                self._fail_attempt(req, "invalid form token: reload the page")
                return
            values = []
            for i, _f in enumerate(req["fields"]):
                # browsers send a textarea's line breaks as CRLF
                v = (form.get(f"v{i}") or [""])[0].replace("\r\n", "\n")
                c = (form.get(f"v{i}_confirm") or [""])[0].replace("\r\n", "\n")
                if not v or not hmac.compare_digest(v.encode(), c.encode()) or len(v) > MAX_VALUE:
                    self._fail_attempt(req, "The values are empty or do not match. Try again.")
                    return
                values.append(v)
            del form, body
            req["state"] = "running"
            _save(req)
        # running -> set | error, whatever happens
        status, page, agent_error = 500, "", "internal error"
        try:
            changes = _recheck(req)
            if changes:
                status, agent_error = 409, ("refused: the flake or the generator changed since the request "
                                            "(or the generator exists now); ask again")
                page = ('<p class="warn"><b>Not stored: this changed since the agent asked.</b> '
                        "Nothing was written. Ask the agent for a new request if this is expected.</p><ul>"
                        + "".join(f"<li><code>{html.escape(c)}</code></li>" for c in changes) + "</ul>")
            else:
                _apply(req, values)
                status, agent_error = 200, ""
                page = ('<p class="ok"><b>Stored.</b> The agent is told it is set. '
                        "You can close this page.</p>")
        except ClanFailed as e:
            agent_error = e.agent_msg
            page = (f'<p class="warn"><b>Storing failed: {html.escape(e.agent_msg)}.</b> The agent sees only '
                    "this line. clan's output (values replaced by &lt;redacted&gt; where found; "
                    "best effort):</p><pre>" + html.escape(e.detail) + "</pre>")
        except Exception as e:  # never stuck in running
            agent_error = f"internal error ({type(e).__name__})"
            page = f'<p class="warn"><b>Storing failed: {html.escape(agent_error)}.</b></p>'
        finally:
            del values
            with _locked(rid):
                req["state"] = "set" if status == 200 else "error"
                req["error"] = agent_error if status != 200 else ""
                _save(req)
        print(f"request {rid[:8]}: {req['machine']} {req['generator']}: {req['state']}", flush=True)
        self._send(status, _page("clan secret", page + _target_html(req)))

    def _fail_attempt(self, req: dict, msg: str) -> None:
        req["attempts"] += 1
        if req["attempts"] >= MAX_ATTEMPTS:
            req["state"] = "error"
            req["error"] = "too many failed submissions"
            _save(req)
            self._gone("error")
            return
        _save(req)
        self._send(400, _form_html(req, msg))


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # the veth address may come up after us
        self.socket.setsockopt(socket.IPPROTO_IP, 15, 1)  # IP_FREEBIND
        super().server_bind()


def cmd_serve(args: argparse.Namespace) -> None:
    host, _, port = args.serve.rpartition(":")
    httpd = Server((host, int(port)), Handler)
    print(f"listening on {args.serve}", flush=True)
    httpd.serve_forever()


def main() -> None:
    ap = argparse.ArgumentParser(
        prog="clan-secret-prompt",
        description="Ask Dave for a clan var's value on a web page; prints only the page's URL.")
    ap.add_argument("machine", nargs="?")
    ap.add_argument("generator", nargs="?")
    ap.add_argument("file", nargs="?", help="the var file to set; omit to answer all of the generator's prompts and run it")
    ap.add_argument("--flake", default=DEFAULT_FLAKE, help=f"the clan flake (default {DEFAULT_FLAKE})")
    ap.add_argument("--reason", help="one line shown to Dave on the page")
    ap.add_argument("--wait", metavar="ID", help="wait for a request; prints set/expired/cancelled/error: ...")
    ap.add_argument("--timeout", type=int, default=0, help="with --wait: give up after this many seconds (prints pending)")
    ap.add_argument("--cancel", metavar="ID")
    ap.add_argument("--serve", metavar="ADDR:PORT", help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.serve:
        cmd_serve(args)
    elif args.wait:
        cmd_wait(args)
    elif args.cancel:
        cmd_cancel(args)
    elif args.machine and args.generator:
        cmd_request(args)
    else:
        ap.print_usage(sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
