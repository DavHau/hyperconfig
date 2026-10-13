"""web_extract backend `local-extract`: fetch and extract on this host.

Each URL runs fetch.py in its own child process under a separate Nix
interpreter (curl_cffi, trafilatura, pymupdf). Those libraries stay out of
the sealed hermes venv, and a hang or crash costs one page, not the agent.
The child gets no secrets: its environment is built from scratch.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any, Dict, List

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

PYTHON = "@python@"
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fetch.py")
# fetch.py bounds each request at 30s; this bounds the redirects and the
# extraction of a large PDF on top.
TIMEOUT = 90


def _failed(url: str, error: str) -> Dict[str, Any]:
    return {"url": url, "title": "", "content": "", "error": error}


async def _extract_one(url: str, fmt: str) -> Dict[str, Any]:
    env = {"HOME": os.environ.get("HOME", "/"), "LANG": "C.UTF-8", "PATH": "/nonexistent"}
    proc = await asyncio.create_subprocess_exec(
        PYTHON, SCRIPT, url, fmt,
        stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return _failed(url, f"Extraction timed out after {TIMEOUT}s.")
    except asyncio.CancelledError:
        proc.kill()
        await proc.wait()
        raise
    try:
        result = json.loads(out)
    except ValueError:
        tail = err.decode("utf-8", "replace").strip().splitlines()[-1:] or [f"exit status {proc.returncode}"]
        logger.warning("local-extract: worker failed for %s: %s", url, tail[0])
        return _failed(url, f"Extractor crashed: {tail[0]}")
    if result.get("error"):
        logger.info("local-extract: %s: %s (%s)", url, result.get("kind"), result.get("status"))
        return _failed(url, result["error"])
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
