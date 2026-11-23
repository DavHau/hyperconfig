"""One upload into a hermes agent's uploads dir (./default.nix).

    upload.py <ssh alias> <status dir> <absolute source dir>

rsync's own resumable copy (-rt, --partial --append-verify) of <source> to
<alias>:<basename>/ (the far end's rrsync roots it in the agent's
uploads dir). Its --info=progress2 output becomes a small JSON status,
written locally to <status dir>/<name>.json and pushed to the far end
every PUSH_EVERY seconds (`agent-upload-status <name>`, the same key's
second verb) and once more at the end. Exits with rsync's code, so the
unit's Restart=on-failure retries a broken link.
"""

import json
import os
import re
import subprocess
import sys
import threading
import time

PUSH_EVERY = 15
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$")
# "  1,234,567  42%  1.23MB/s  0:01:02 (xfr#3, to-chk=10/20)"
PROGRESS_RE = re.compile(
    r"([\d,]+)\s+(\d+)%\s+(\S+/s)\s+(\d+:\d\d:\d\d)"
    r"(?:\s+\(xfr#(\d+), (?:ir|to)-chk=(\d+)/(\d+)\))?"
)


def scan(src):
    files = size = 0
    for root, dirs, names in os.walk(src):
        for n in names:
            try:
                st = os.lstat(os.path.join(root, n))
            except OSError:
                continue
            files += 1
            size += st.st_size
    return files, size


def main():
    alias, status_dir, src = sys.argv[1:4]
    src = os.path.normpath(src)
    name = os.path.basename(src)
    if not os.path.isabs(src) or not os.path.isdir(src):
        sys.exit(f"not an absolute directory: {src}")
    if not NAME_RE.match(name):
        sys.exit(f"source dir name {name!r} must match {NAME_RE.pattern}")

    files_total, bytes_total = scan(src)
    status = {
        "name": name,
        "source": src,
        "state": "starting",
        "files_total": files_total,
        "files_done": 0,
        "bytes_total": bytes_total,
        "bytes_done": 0,
        "percent": 0,
        "rate": "",
        "eta": "",
        "started": int(time.time()),
        "updated": int(time.time()),
        "exit_code": None,
    }
    lock = threading.Lock()
    os.makedirs(status_dir, exist_ok=True)
    local = os.path.join(status_dir, name + ".json")

    def snapshot():
        with lock:
            status["updated"] = int(time.time())
            return json.dumps(status, separators=(",", ":")) + "\n"

    def write_local(data):
        tmp = local + ".tmp"
        with open(tmp, "w") as f:
            f.write(data)
        os.replace(tmp, local)

    def push(data):
        try:
            subprocess.run(
                ["ssh", alias, "agent-upload-status", name],
                input=data.encode(),
                timeout=60,
                check=False,
                stdout=subprocess.DEVNULL,
            )
        except subprocess.TimeoutExpired:
            pass

    stop = threading.Event()

    def pusher():
        while not stop.wait(PUSH_EVERY):
            data = snapshot()
            write_local(data)
            push(data)

    t = threading.Thread(target=pusher, daemon=True)
    t.start()

    # No trailing slash on the source: rsync creates <name>/ in the far
    # end's root (rrsync's pinned paths refuse a named target dir).
    cmd = [
        "rsync",
        "-rt",
        # resume: a broken file stays in place (--partial) and the next
        # run sends only its rest, checking the whole file at the end.
        # Not --partial-dir: rsync refuses it with --append-verify, and
        # rrsync's pinned paths lose a partial dir's file on a drop.
        "--partial",
        "--append-verify",
        "--no-inc-recursive",
        "--timeout=120",
        "-z",
        "--info=progress2",
        src,
        f"{alias}:",
    ]
    with lock:
        status["state"] = "running"
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    assert proc.stdout is not None
    out_fd = proc.stdout.fileno()
    buf = b""
    while True:
        chunk = os.read(out_fd, 4096)
        if not chunk:
            break
        buf += chunk
        parts = re.split(rb"[\r\n]", buf)
        buf = parts.pop()
        for line in parts:
            m = PROGRESS_RE.search(line.decode(errors="replace"))
            if not m:
                continue
            with lock:
                status["bytes_done"] = int(m.group(1).replace(",", ""))
                status["percent"] = int(m.group(2))
                status["rate"] = m.group(3)
                status["eta"] = m.group(4)
                if m.group(6) is not None:
                    left, total = int(m.group(6)), int(m.group(7))
                    # to-chk counts directories too: clamp to the files
                    status["files_done"] = max(0, min(files_total, files_total - left))
    rc = proc.wait()
    stop.set()
    with lock:
        status["exit_code"] = rc
        if rc == 0:
            status["state"] = "done"
            status["files_done"] = files_total
            status["percent"] = 100
            status["eta"] = "0:00:00"
        else:
            status["state"] = "retrying"
    data = snapshot()
    write_local(data)
    push(data)
    print(f"rsync exited {rc}", file=sys.stderr)
    sys.exit(rc)


if __name__ == "__main__":
    main()
