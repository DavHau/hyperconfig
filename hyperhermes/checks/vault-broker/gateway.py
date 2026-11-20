"""Stand-in gateway for the vault-broker check (./default.nix): runs as the main process of alice's
hermes-agent unit, like hermes' gateway, and resolves through hermes' own VaultStore what the test
asks for: one request file `<handle> <home>` in, one result file out (a digest of the card number,
or the refusal), as hermes' browser_vault fill would resolve it."""
import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

from agent.vault_store import VaultStore

req = Path(os.environ["FILL_DIR"]) / "request"
out = Path(os.environ["FILL_DIR"]) / "result"
while True:
    if req.exists():
        handle, home = req.read_text().split()
        req.unlink()
        if handle.startswith("child:"):
            # a process this one starts (a terminal command, a script): another pid
            run = subprocess.run([sys.executable, os.environ["AGENT_PY"], "resolve", home, handle[6:]],
                                 capture_output=True, text=True, check=False)
            result = "child " + (run.stdout.strip().splitlines() or [run.stderr[-300:]])[-1]
            out.with_suffix(".tmp").write_text(result)
            out.with_suffix(".tmp").rename(out)
            continue
        try:
            secret = VaultStore(base_dir=Path(home) / "vault").resolve_secret(handle)
            value = secret.get("card_number") or secret.get("password") or ""
            result = "ok " + hashlib.sha256(value.encode()).hexdigest()
        except Exception as exc:
            result = f"refused {type(exc).__name__}: {exc}"
        tmp = out.with_suffix(".tmp")
        tmp.write_text(result)
        tmp.rename(out)
    time.sleep(0.1)
