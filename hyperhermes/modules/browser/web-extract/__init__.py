"""web_extract backend `local-extract`: fetch and extract on this host.

Each URL runs fetch.py in its own child process under a separate Nix
interpreter (curl_cffi, trafilatura, pymupdf, camoufox). Those libraries
stay out of the sealed hermes venv, and a hang or crash costs one page,
not the agent. The child gets no secrets: its environment is built from
scratch, with HOME and TMPDIR in its own temp dir. It runs in its own
process group, so a timeout takes its browser down, and the temp dir,
browser profile included, goes with it.

At most MAX_WORKERS of them run at once in this process, whichever
session, subagent or cron job asked (each may start a headless Camoufox);
the others wait for a slot within their own timeout. web_extract_residential
gives each task its own sticky residential exit (a proxy session id derived
from the task and country), so parallel subagents neither share nor hop IPs.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import signal
import tempfile
import threading
import time
import hashlib
import re
from typing import Any, Dict, List, Optional

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

PYTHON = "@python@"
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fetch.py")
# fetch.py keeps a URL, browser retry included, inside 100s; this is
# the hard stop, under hermes' 120s cap for the whole web_extract call.
TIMEOUT = 110
# Concurrent fetch.py workers per process (all sessions, subagents, cron).
MAX_WORKERS = int(os.environ.get("HERMES_WEB_EXTRACT_MAX_WORKERS", "6") or 6)
# A threading semaphore: tool handlers run their coroutines on different
# event loops (one per tool thread), which an asyncio one cannot span.
_WORKERS = threading.BoundedSemaphore(MAX_WORKERS)


async def _worker_slot(deadline: float) -> bool:
    while not _WORKERS.acquire(blocking=False):
        if time.monotonic() >= deadline:
            return False
        await asyncio.sleep(0.2)
    return True


def residential_session(task_id: Optional[str], country: str) -> str:
    """The proxy's sticky session id of this task and country (6-10 alphanumerics)."""
    return hashlib.sha256(f"{task_id or 'default'}:{country.lower()}".encode()).hexdigest()[:10]


def _failed(url: str, error: str) -> Dict[str, Any]:
    return {"url": url, "title": "", "content": "", "error": error}


async def _stop(proc: asyncio.subprocess.Process) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    await proc.wait()


async def _extract_one(url: str, fmt: str, country: Optional[str] = None,
                       session: Optional[str] = None) -> Dict[str, Any]:
    deadline = time.monotonic() + TIMEOUT
    if not await _worker_slot(deadline):
        return _failed(url, f"Extraction did not start within {TIMEOUT}s: {MAX_WORKERS} extractions already run in this agent.")
    try:
        return await _extract_in_worker(url, fmt, country, session, deadline)
    finally:
        _WORKERS.release()


async def _extract_in_worker(url: str, fmt: str, country: Optional[str], session: Optional[str],
                             deadline: float) -> Dict[str, Any]:
    tmp = tempfile.mkdtemp(prefix="local-extract-")
    try:
        env = {"HOME": tmp, "LANG": "C.UTF-8", "PATH": "/nonexistent", "TMPDIR": tmp}
        args = [url, fmt]
        if country:
            # Only the proxy's address: it holds no secret (the proxy keeps
            # the provider's credentials and gates who connects).
            env["RESIDENTIAL_PROXY_URL"] = os.environ.get("RESIDENTIAL_PROXY_URL", "")
            args.append(country)
            if session:
                args.append(session)
        proc = await asyncio.create_subprocess_exec(
            PYTHON, SCRIPT, *args,
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=env, start_new_session=True,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=max(deadline - time.monotonic(), 1))
        except asyncio.TimeoutError:
            await _stop(proc)
            return _failed(url, f"Extraction did not finish within {TIMEOUT}s (waiting for a free worker included).")
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


# ---- web_extract_residential: the same extraction through the host's residential proxy ----
# Offered only when the host has one (RESIDENTIAL_PROXY_URL in the agent's .env, set by
# hyperhermes' browser.residentialProxy). Opt-in per call: web_extract itself never uses it.

RESIDENTIAL_SCHEMA = {
    "name": "web_extract_residential",
    "description": (
        "Like web_extract, but the request leaves through a residential (home) IP address via this "
        "host's paid residential proxy, in the chosen country. Use ONLY after web_extract or the "
        "browser was blocked by the site (403, bot wall, 'access denied', region block); it costs "
        "paid traffic. Never for logging in to the owner's accounts unless asked. If it answers that "
        "the proxy's traffic is used up, do not retry: go on without it and tell the user."),
    "parameters": {
        "type": "object",
        "properties": {
            "urls": {"type": "array", "items": {"type": "string"}, "maxItems": 5,
                     "description": "Up to 5 http(s) URLs."},
            "country": {"type": "string", "pattern": "^[A-Za-z]{2}$",
                        "description": "Exit country, ISO 3166 two-letter code (default: the proxy's, SG)."},
            "format": {"type": "string", "enum": ["markdown", "text"], "default": "markdown"},
        },
        "required": ["urls"],
    },
}


def _residential_available() -> bool:
    return bool(re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", os.environ.get("RESIDENTIAL_PROXY_URL", "")))


async def _handle_residential(args: Dict[str, Any], task_id: Optional[str] = None, **_: Any) -> str:
    urls = [str(u) for u in (args.get("urls") or [])][:5]
    if not urls:
        return json.dumps({"success": False, "error": "urls is required"})
    country = str(args.get("country") or os.environ.get("RESIDENTIAL_PROXY_COUNTRY", "SG"))
    if not re.fullmatch(r"[A-Za-z]{2}", country):
        return json.dumps({"success": False, "error": "country must be a two-letter ISO code, e.g. SG, US, DE"})
    fmt = "text" if args.get("format") == "text" else "markdown"
    session = residential_session(task_id, country)
    results = await asyncio.gather(*(_extract_one(u, fmt, country.upper(), session) for u in urls))
    return json.dumps({"via": f"residential proxy ({country.upper()})", "results": list(results)},
                      ensure_ascii=False)


def register(ctx) -> None:
    ctx.register_web_search_provider(LocalExtractProvider())
    if _residential_available():
        ctx.register_tool(name="web_extract_residential", toolset="web", schema=RESIDENTIAL_SCHEMA,
                          handler=_handle_residential, check_fn=_residential_available, is_async=True,
                          emoji="🏠")
