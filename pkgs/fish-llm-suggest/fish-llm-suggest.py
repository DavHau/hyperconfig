"""Live LLM autosuggestions for fish.

`fish-llm-suggest wrap -- CMD...` runs CMD (an interactive fish) on a pty and
proxies the terminal byte for byte. While proxying it

* records the last few executed commands with exit status and a short,
  escape-stripped output tail, segmented by the OSC 133 C/D marks fish emits
  around every command (full-screen programs are noted, not recorded);
* listens on a datagram socket that the patched fish notifies from its
  autosuggestion thread (`fish_autosuggestion_socket`): `h<line>` means the line
  already has a suggestion (history or an earlier LLM candidate), `m<line>` means
  it has none;
* after the line stays unchanged for the debounce interval, asks the
  OpenAI-compatible endpoint for a completion (at most one request in flight,
  stale ones aborted, results cached) and hands the result to fish: it writes
  `<line>\\0<suggestion>` to $FISH_LLM_RESULT and sends SIGUSR1, whose handler
  puts the suggestion into `fish_autosuggestion_extra`, which fish renders as
  ordinary autosuggestion ghost text.

Failures are silent; with FISH_LLM_LOG set, events go to that file.
"""

import collections
import errno
import fcntl
import http.client
import json
import os
import pty
import re
import select
import signal
import socket
import subprocess
import sys
import termios
import threading
import time
import tty
import urllib.parse


def env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


API_URL = os.environ.get("FISH_LLM_URL", "https://inference.p0.contact/v1")
MODEL = os.environ.get("FISH_LLM_MODEL", "qwen")
KEY_COMMAND = os.environ.get("FISH_LLM_KEY_COMMAND", "p0-api-key")
DEBOUNCE = env_int("FISH_LLM_DEBOUNCE_MS", 400) / 1000
MIN_CHARS = env_int("FISH_LLM_MIN_CHARS", 3)
TIMEOUT = env_int("FISH_LLM_TIMEOUT_MS", 5000) / 1000
MAX_TOKENS = env_int("FISH_LLM_MAX_TOKENS", 64)
CONTEXT_COMMANDS = env_int("FISH_LLM_CONTEXT_COMMANDS", 5)
OUTPUT_LINES = env_int("FISH_LLM_OUTPUT_LINES", 15)
OUTPUT_CHARS = env_int("FISH_LLM_OUTPUT_CHARS", 1200)
LOG_PATH = os.environ.get("FISH_LLM_LOG")

# Raw bytes kept per running command; only the tail matters.
RAW_TAIL = 16 * 1024
CACHE_SIZE = 256

SYSTEM_PROMPT = (
    "You are the autosuggestion engine of an interactive fish shell on NixOS. "
    "Given the recent commands with their output and the partially typed command line, "
    "predict the complete command line the user is most likely typing. "
    "Use the recent output (errors, file names, hints) when relevant. "
    "Reply with the full command line only, beginning exactly with the typed text, "
    "on a single line, without quotes, markdown or explanation."
)

_log_lock = threading.Lock()


def log(event, **fields):
    if not LOG_PATH:
        return
    fields = " ".join(f"{k}={json.dumps(v)}" for k, v in fields.items())
    with _log_lock, open(LOG_PATH, "a") as f:
        f.write(f"{time.time():.3f} {os.getpid()} {event} {fields}\n")


# --- terminal output recorder ---------------------------------------------

CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
ESC_RE = re.compile(r"\x1b[@-Z\\-_]|\x1b[()][0-9A-Za-z]")
CTRL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
ALT_SCREEN = (b"\x1b[?1049h", b"\x1b[?1047h", b"\x1b[?47h")
OSC133 = b"\x1b]133;"


def clean_output(raw):
    text = raw.decode("utf-8", "replace")
    text = OSC_RE.sub("", text)
    text = CSI_RE.sub("", text)
    text = ESC_RE.sub("", text)
    lines = []
    for line in text.split("\n"):
        line = line.rstrip("\r")
        # Carriage returns redraw the line (progress bars): keep the last state.
        line = line.rsplit("\r", 1)[-1]
        while "\b" in line:
            line = re.sub(r"[^\b]\b|^\b+", "", line, count=1)
        lines.append(CTRL_RE.sub("", line).rstrip())
    while lines and not lines[-1]:
        lines.pop()
    while lines and not lines[0]:
        lines.pop(0)
    lines = lines[-OUTPUT_LINES:]
    text = "\n".join(lines)
    if len(text) > OUTPUT_CHARS:
        text = "…" + text[-OUTPUT_CHARS:]
    return text


class Recorder:
    """Splits the pty output stream into commands using fish's OSC 133 marks."""

    def __init__(self, on_command_start):
        self.on_command_start = on_command_start
        self.history = collections.deque(maxlen=max(CONTEXT_COMMANDS, 1))
        self.pending = b""
        self.cmd = None  # command line of the running command
        self.raw = bytearray()
        self.fullscreen = False
        self.lock = threading.Lock()

    def feed(self, data):
        data = self.pending + data
        self.pending = b""
        pos = 0
        while True:
            mark = data.find(OSC133, pos)
            if mark < 0:
                # Hold back a possible start of a mark split across reads.
                keep = 0
                for n in range(min(len(OSC133) - 1, len(data) - pos), 0, -1):
                    if OSC133.startswith(data[len(data) - n :]):
                        keep = n
                        break
                self._output(data[pos : len(data) - keep])
                self.pending = data[len(data) - keep :]
                return
            self._output(data[pos:mark])
            end_bel = data.find(b"\x07", mark)
            end_st = data.find(b"\x1b\\", mark)
            ends = [e for e in (end_bel, end_st) if e >= 0]
            if not ends:
                if len(data) - mark < 4096:
                    self.pending = data[mark:]
                    return
                pos = mark + len(OSC133)  # garbage, skip it
                continue
            end = min(ends)
            self._mark(data[mark + len(OSC133) : end])
            pos = end + (1 if end == end_bel else 2)

    def _output(self, chunk):
        if self.cmd is None or not chunk:
            return
        if not self.fullscreen and any(seq in chunk for seq in ALT_SCREEN):
            self.fullscreen = True
        self.raw += chunk
        if len(self.raw) > RAW_TAIL:
            del self.raw[: len(self.raw) - RAW_TAIL]

    def _mark(self, body):
        body = body.decode("utf-8", "replace")
        kind, _, params = body.partition(";")
        if kind == "C":
            cmd = ""
            for param in params.split(";"):
                if param.startswith("cmdline_url="):
                    cmd = urllib.parse.unquote(param[len("cmdline_url=") :])
            self.cmd = cmd
            self.raw = bytearray()
            self.fullscreen = False
            self.on_command_start()
        elif kind == "D" and self.cmd is not None:
            status = params.split(";", 1)[0] or "?"
            if self.fullscreen:
                output = "(full-screen program, output not recorded)"
            else:
                output = clean_output(bytes(self.raw))
            with self.lock:
                self.history.append((self.cmd, status, output))
            self.cmd = None
            self.raw = bytearray()

    def context(self):
        with self.lock:
            entries = list(self.history)[-CONTEXT_COMMANDS:] if CONTEXT_COMMANDS else []
        parts = []
        for cmd, status, output in entries:
            parts.append(f"$ {cmd}\n{output + chr(10) if output else ''}[exit {status}]")
        return "\n".join(parts)


# --- suggestion engine ------------------------------------------------------


class Cancelled(Exception):
    pass


class Suggester:
    def __init__(self, fish_pid, result_path, recorder):
        self.fish_pid = fish_pid
        self.result_path = result_path
        self.recorder = recorder
        self.cond = threading.Condition()
        self.latest = None  # last line fish reported
        self.pending = None  # line waiting for the debounce deadline
        self.deadline = 0.0
        self.inflight = None  # line being requested
        self.inflight_sock = None
        self.last_delivered = None
        self.cache = collections.OrderedDict()  # (cwd, line) -> suggestion or None
        self.conn = None
        self.key = None
        self.requests = 0
        threading.Thread(target=self._worker, daemon=True).start()

    def cwd(self):
        try:
            return os.readlink(f"/proc/{self.fish_pid}/cwd")
        except OSError:
            return ""

    @staticmethod
    def eligible(line):
        return (
            len(line.strip()) >= MIN_CHARS
            and not line.startswith(" ")  # fish keeps these out of history: private
            and not line.lstrip().startswith("#")  # fish-ai turns comments into commands
            and "\n" not in line
        )

    def _cached(self, cwd, line):
        hit = self.cache.get((cwd, line), False)
        if hit is not False:
            return hit
        for (c, prefix), sugg in reversed(self.cache.items()):
            if c == cwd and sugg and line.startswith(prefix) and sugg.startswith(line) and len(sugg) > len(line):
                return sugg
        return False

    def _abort_inflight(self):
        if self.inflight_sock is not None:
            try:
                self.inflight_sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        log("cancel", line=self.inflight)
        self.inflight = None

    def on_command_start(self):
        with self.cond:
            self.pending = None
            self.latest = None
            self.last_delivered = None
            if self.inflight is not None:
                self._abort_inflight()

    def on_message(self, kind, line):
        with self.cond:
            self.latest = line
            if kind != "m" or not self.eligible(line):
                self.pending = None
                if self.inflight is not None and not (kind == "h" and line.startswith(self.inflight)):
                    self._abort_inflight()
                return
            if self.inflight is not None:
                if line.startswith(self.inflight):
                    # Typed on: the running answer may still fit; keep it and queue this line.
                    pass
                else:
                    self._abort_inflight()
            hit = self._cached(self.cwd(), line)
            if hit is not False:
                self.pending = None
                if hit and self.last_delivered != (line, hit):
                    self._deliver(line, hit)
                return
            if line == self.inflight:
                self.pending = None
                return
            self.pending = line
            self.deadline = time.monotonic() + DEBOUNCE
            self.cond.notify()

    def _deliver(self, line, suggestion):
        tmp = f"{self.result_path}.tmp"
        try:
            with open(tmp, "w") as f:
                f.write(f"{line}\0{suggestion}")
            os.replace(tmp, self.result_path)
            os.kill(self.fish_pid, signal.SIGUSR1)
        except OSError:
            return
        self.last_delivered = (line, suggestion)
        log("deliver", line=line, suggestion=suggestion)

    def _worker(self):
        while True:
            with self.cond:
                while True:
                    now = time.monotonic()
                    if self.pending is not None and self.inflight is None and now >= self.deadline:
                        break
                    timeout = None
                    if self.pending is not None and self.inflight is None:
                        timeout = self.deadline - now
                    self.cond.wait(timeout)
                line = self.pending
                self.pending = None
                self.inflight = line
            cwd = self.cwd()
            started = time.monotonic()
            try:
                suggestion = self._request(line, cwd)
                error = None
            except Exception as e:  # silent by design
                suggestion, error = None, f"{type(e).__name__}: {e}"
                self._drop_conn()
            latency = round((time.monotonic() - started) * 1000)
            with self.cond:
                aborted = self.inflight != line
                self.inflight = None
                self.inflight_sock = None
                log("response", line=line, suggestion=suggestion, ms=latency, error=error, aborted=aborted)
                if error is None or not aborted:
                    self._remember(cwd, line, suggestion if error is None else None)
                latest = self.latest
                if suggestion and latest is not None and suggestion.startswith(latest) and len(suggestion) > len(latest):
                    if self.pending is not None and suggestion.startswith(self.pending):
                        self.pending = None
                    self._deliver(latest, suggestion)
                self.cond.notify()

    def _remember(self, cwd, line, suggestion):
        self.cache[(cwd, line)] = suggestion
        self.cache.move_to_end((cwd, line))
        while len(self.cache) > CACHE_SIZE:
            self.cache.popitem(last=False)

    def _drop_conn(self):
        if self.conn is not None:
            self.conn.close()
        self.conn = None

    def _api_key(self):
        if self.key is None:
            self.key = subprocess.run(
                [KEY_COMMAND], capture_output=True, text=True, timeout=5, check=True
            ).stdout.strip()
        return self.key

    def _prompt(self, line, cwd):
        try:
            entries = sorted(os.listdir(cwd))
        except OSError:
            entries = []
        files = " ".join(entries[:40]) + (" …" if len(entries) > 40 else "")
        context = self.recorder.context() or "(none)"
        return (
            f"Working directory: {cwd}\n"
            f"Files there: {files or '(none)'}\n\n"
            f"Recent commands with output (oldest first):\n{context}\n\n"
            f"Typed so far: {line}"
        )

    def _request(self, line, cwd):
        url = urllib.parse.urlsplit(API_URL)
        if self.conn is None:
            cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
            self.conn = cls(url.netloc, timeout=TIMEOUT)
        body = {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": self._prompt(line, cwd)},
            ],
            "max_tokens": MAX_TOKENS,
            "temperature": 0,
            "stop": ["\n"],
            # Qwen: answer directly instead of reasoning first.
            "chat_template_kwargs": {"enable_thinking": False},
        }
        headers = {"Authorization": f"Bearer {self._api_key()}", "Content-Type": "application/json"}
        self.requests += 1
        log("request", line=line, n=self.requests, prompt=body["messages"][1]["content"])
        if self.conn.sock is None:
            self.conn.connect()
        with self.cond:
            if self.inflight != line:
                raise Cancelled()
            self.inflight_sock = self.conn.sock
        self.conn.request("POST", url.path.rstrip("/") + "/chat/completions", json.dumps(body), headers)
        resp = self.conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {data[:200]!r}")
        content = json.loads(data)["choices"][0]["message"].get("content") or ""
        suggestion = self._extract(line, content)
        if suggestion is None:
            log("unusable", line=line, content=content)
        return suggestion

    @staticmethod
    def _extract(line, content):
        text = content.strip().strip("`").strip()
        if text.startswith(("fish\n", "sh\n", "bash\n")):
            text = text.split("\n", 1)[1]
        text = text.split("\n", 1)[0].rstrip()
        if text.startswith("$ "):
            text = text[2:]
        if text.startswith(line) and len(text) > len(line):
            return text
        return None


# --- pty proxy --------------------------------------------------------------


def copy_winsize(src_fd, dst_fd):
    try:
        size = fcntl.ioctl(src_fd, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(dst_fd, termios.TIOCSWINSZ, size)
    except OSError:
        pass


def write_all(fd, data):
    while data:
        try:
            n = os.write(fd, data)
        except InterruptedError:
            continue
        data = data[n:]


def wrap(argv):
    runtime = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/fish-llm-{os.getuid()}", "fish-llm-suggest")
    os.makedirs(runtime, mode=0o700, exist_ok=True)
    sock_path = os.path.join(runtime, f"{os.getpid()}.sock")
    result_path = os.path.join(runtime, f"{os.getpid()}.result")
    for p in (sock_path, result_path):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(sock_path)
    sock.setblocking(False)

    stdin_tty = os.isatty(0)
    pid, master = pty.fork()
    if pid == 0:
        sock.close()
        os.environ["FISH_LLM_SOCKET"] = sock_path
        os.environ["FISH_LLM_RESULT"] = result_path
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)

    if stdin_tty:
        copy_winsize(0, master)
        saved = termios.tcgetattr(0)
        tty.setraw(0)
    signal.signal(signal.SIGWINCH, lambda *_: copy_winsize(0, master))
    # Terminal closed / killed: leave through the cleanup below (fish gets SIGHUP from the pty).
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, lambda signum, _: sys.exit(128 + signum))

    suggester = None

    def on_command_start():
        if suggester is not None:
            suggester.on_command_start()

    recorder = Recorder(on_command_start)
    suggester = Suggester(pid, result_path, recorder)
    log("start", argv=argv, socket=sock_path)

    fds = [master, sock, 0]
    try:
        while True:
            try:
                ready, _, _ = select.select(fds, [], [])
            except InterruptedError:
                continue
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError as e:
                    if e.errno != errno.EIO:
                        raise
                    data = b""
                if not data:
                    break
                write_all(1, data)
                try:
                    recorder.feed(data)
                except Exception as e:  # never let parsing break the terminal
                    log("recorder-error", error=repr(e))
            if 0 in ready:
                data = os.read(0, 65536)
                if data:
                    write_all(master, data)
                else:
                    fds.remove(0)
            if sock in ready:
                while True:
                    try:
                        msg = sock.recv(65536)
                    except BlockingIOError:
                        break
                    if msg:
                        kind, line = chr(msg[0]), msg[1:].decode("utf-8", "replace")
                        log("msg", kind=kind, line=line)
                        suggester.on_message(kind, line)
    finally:
        if stdin_tty:
            try:
                termios.tcsetattr(0, termios.TCSAFLUSH, saved)
            except termios.error:
                pass
        for p in (sock_path, result_path):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        log("exit", requests=suggester.requests)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 1


def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "wrap":
        args = args[1:]
        if args[0] == "--":
            args = args[1:]
        if args:
            sys.exit(wrap(args))
    print("usage: fish-llm-suggest wrap [--] COMMAND [ARGS...]", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
