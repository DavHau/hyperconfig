"""web_extract backend `local-extract`: fetch and extract on this host.

Each URL runs fetch.py in its own child process under a separate Nix
interpreter (curl_cffi, trafilatura, pymupdf, playwright). Those libraries
stay out of the sealed hermes venv, and a hang or crash costs one page,
not the agent. The child gets no secrets: its environment is built from
scratch, plus the agent's X display for the browser retry. It runs in its
own process group and temp dir, so a timeout takes its browser down and
the browser profile with it.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import signal
import tempfile
from typing import Any, Dict, List

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

PYTHON = "@python@"
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fetch.py")
# fetch.py keeps a URL, browser retry included, inside 100s; this is
# the hard stop, under hermes' 120s cap for the whole web_extract call.
TIMEOUT = 110


def _failed(url: str, error: str) -> Dict[str, Any]:
    return {"url": url, "title": "", "content": "", "error": error}


async def _stop(proc: asyncio.subprocess.Process) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    await proc.wait()


async def _extract_one(url: str, fmt: str) -> Dict[str, Any]:
    tmp = tempfile.mkdtemp(prefix="local-extract-")
    try:
        env = {"HOME": os.environ.get("HOME", "/"), "LANG": "C.UTF-8", "PATH": "/nonexistent", "TMPDIR": tmp}
        env.update({k: os.environ[k] for k in ("DISPLAY", "XAUTHORITY") if k in os.environ})
        proc = await asyncio.create_subprocess_exec(
            PYTHON, SCRIPT, url, fmt,
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=env, start_new_session=True,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=TIMEOUT)
        except asyncio.TimeoutError:
            await _stop(proc)
            return _failed(url, f"Extraction timed out after {TIMEOUT}s.")
        except asyncio.CancelledError:
            await _stop(proc)
            raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    try:
        result = json.loads(out)
    except ValueError:
        tail = err.decode("utf-8", "replace").strip().splitlines()[-1:] or [f"exit status {proc.returncode}"]
        logger.warning("local-extract: worker failed for %s: %s", url, tail[0])
        return _failed(url, f"Extractor crashed: {tail[0]}")
    if result.get("error"):
        logger.info("local-extract: %s: %s (%s)", url, result.get("kind"), result.get("status"))
        return _failed(url, result["error"])
    if result.get("via") == "browser":
        logger.info("local-extract: %s: rendered in the browser", url)
    title = result.get("title", "")
    return {
        "url": url, "title": title, "content": result["content"], "raw_content": result["content"],
        "metadata": {"sourceURL": url, "title": title},
    }


class LocalExtractProvider(WebSearchProvider):
    @property
    def name(self) -> str:
        return "local-extract"

    @property
    def display_name(self) -> str:
        return "Local extract (curl_cffi + trafilatura)"

    def is_available(self) -> bool:
        return os.access(PYTHON, os.X_OK)

    def supports_search(self) -> bool:
        return False

    def supports_extract(self) -> bool:
        return True

    async def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
        fmt = "text" if kwargs.get("format") == "text" else "markdown"
        return list(await asyncio.gather(*(_extract_one(u, fmt) for u in urls)))


def register(ctx) -> None:
    ctx.register_web_search_provider(LocalExtractProvider())
