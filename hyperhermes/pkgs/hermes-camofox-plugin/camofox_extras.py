"""hyperhermes' additions to the Camofox plugin: browser_downloads and browser_solve_captcha.

Both were core patches while Camofox was in core (hyperhermes
modules/core/patches/hermes-camofox-{browser-downloads,solve-captcha}.patch, hermes v0.22.5); they
moved with Camofox into this plugin. Neither is upstream (NousResearch/hermes-agent#52939 asks for
the downloads; no captcha hook exists in hermes or camofox-browser).
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Optional

import requests

from tools.registry import tool_error

from . import camofox_client as client


def _fail(message: str) -> str:
    return tool_error(message, success=False)


# ---- Downloads ----
# camofox-browser saves every download a tab starts (link, form response, script) into its own
# temp dir and lists it under GET /tabs/<id>/downloads once saved; it keeps the last 20 per tab
# and deletes them when the tab or session closes. Popups (ad tabs, target=_blank forms) are
# tabs of the same userId, so listing walks every tab of this agent's userId, and only those.
# includeData inlines base64 for every record up to maxBytes, so a save asks for exactly the
# chosen record's size; the cap is camofox's own limit for files it stores
# (MAX_FETCHED_RESOURCE_BYTES).
_DOWNLOAD_MAX_BYTES = 50 * 1024 * 1024
_DOWNLOAD_WAIT_SECONDS = 15.0
_DOWNLOAD_POLL_SECONDS = 1.0


def _session_downloads(session: dict[str, Any]) -> Optional[list[dict[str, Any]]]:
    """Every download record of this task's tabs (its session key; popups carry it too), oldest
    first, each tagged with its tab; None when the task has no tab at all. Other tasks sharing the
    userId (parallel sessions on the profile's context) keep theirs."""
    tabs = client.get("/tabs", params=client.user_params(session)).get("tabs") or []
    tabs = [t for t in tabs if isinstance(t, dict) and t.get("listItemId") in (None, session.get("session_key"))]
    if not tabs:
        return None
    items: list[dict[str, Any]] = []
    for tab in tabs:
        tab_id = tab.get("tabId") if isinstance(tab, dict) else None
        if not tab_id:
            continue
        try:
            data = client.get(f"/tabs/{tab_id}/downloads", params=client.user_params(session))
        except requests.HTTPError as e:
            if e.response is not None and e.response.status_code in (404, 410):
                continue  # closed between the two calls
            raise
        for record in data.get("downloads", []):
            if isinstance(record, dict) and record.get("id"):
                items.append({**record, "_tab_id": tab_id})
    items.sort(key=lambda r: str(r.get("createdAt") or ""))
    return items


def _download_view(record: dict[str, Any]) -> dict[str, Any]:
    failure = record.get("failure")
    return {"id": record["id"], "filename": record.get("suggestedFilename"), "size": record.get("bytes"),
            "mime": record.get("mimeType"), "url": record.get("url"), "created": record.get("createdAt"),
            "status": f"failed: {failure}" if failure else "complete"}


def _wait_for_new_download(session: dict[str, Any]) -> Optional[list[dict[str, Any]]]:
    """List downloads; when none is new since this task last looked, poll briefly, since camofox
    lists a download only after it finished saving it."""
    seen = session.setdefault("seen_downloads", set())
    deadline = time.monotonic() + _DOWNLOAD_WAIT_SECONDS
    while True:
        items = _session_downloads(session)
        if items is None or any(r["id"] not in seen for r in items) or time.monotonic() >= deadline:
            return items
        time.sleep(_DOWNLOAD_POLL_SECONDS)


def _download_destination(task_id: Optional[str], path: Optional[str], filename: str) -> Path:
    """Resolve the save target inside the agent's working directory, the base the file tools
    use. Symlinks are resolved before the containment check, so neither ``..`` nor a link
    leads out; the page-chosen filename only ever supplies the last component."""
    from tools.file_tools_paths import _resolve_base_dir, _uses_container_paths
    task = task_id or "default"
    if _uses_container_paths(task):
        raise ValueError("Saving downloads needs a local terminal backend: the working directory "
                         "is inside a container this process cannot write to.")
    root = Path(_resolve_base_dir(task, container_paths=False)).resolve()
    name = os.path.basename(filename) or "download.bin"
    if name in (".", ".."):
        name = "download.bin"
    target = Path(os.path.expanduser(path)) if path else Path(name)
    if not target.is_absolute():
        target = root / target
    if path and (path.endswith(("/", os.sep)) or target.is_dir()):
        target = target / name
    target = target.resolve()
    if root not in target.parents:
        raise ValueError(f"Refusing to save outside the working directory {root}: {target}")
    return target


def _write_new_file(target: Path, raw: bytes, overwrite: bool) -> None:
    """Write via a temp file in the target's directory; without ``overwrite`` the final link
    fails on an existing file, so a file that appears meanwhile is not replaced either."""
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=".download-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
        if overwrite:
            os.replace(tmp, target)
        else:
            os.link(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _save_download(session: dict[str, Any], items: list[dict[str, Any]], save: str,
                   path: Optional[str], overwrite: bool, task_id: Optional[str]) -> str:
    done = [r for r in items if not r.get("failure")]
    if save == "latest":
        record = done[-1] if done else None
    else:
        record = next((r for r in items if r["id"] == save), None)
    if record is None:
        return _fail(f"No download {save!r} in this browser session. Call browser_downloads "
                     "without arguments to list them.")
    if record.get("failure"):
        return _fail(f"Download {record['id']} failed in the browser: {record['failure']}")
    size = record.get("bytes")
    if not isinstance(size, int) or size < 0:
        return _fail(f"Download {record['id']} has no recorded size.")
    if size > _DOWNLOAD_MAX_BYTES:
        return _fail(f"Download {record['id']} is {size} bytes, over the {_DOWNLOAD_MAX_BYTES}-byte "
                     f"limit; fetch its URL with curl instead: {record.get('url')}")
    target = _download_destination(task_id, path, str(record.get("suggestedFilename") or ""))
    if target.exists() and not overwrite:
        return _fail(f"{target} exists; pass overwrite=true to replace it, or another path.")

    data = client.get(f"/tabs/{record['_tab_id']}/downloads",
                      params={**client.user_params(session), "includeData": "true", "maxBytes": str(max(size, 1))},
                      timeout=max(client.get_command_timeout(), 120))
    entry = next((d for d in data.get("downloads", []) if d.get("id") == record["id"]), None)
    if entry is None:
        return _fail(f"Download {record['id']} is gone from the browser (its tab was closed).")
    if "dataBase64" not in entry:
        reason = entry.get("readError") or entry.get("dataSkipped") or "no data returned"
        return _fail(f"Camofox could not return download {record['id']}: {reason}")
    raw = base64.b64decode(entry["dataBase64"])
    if len(raw) != size:
        return _fail(f"Download {record['id']} arrived with {len(raw)} of {size} bytes.")
    try:
        _write_new_file(target, raw, overwrite)
    except FileExistsError:
        return _fail(f"{target} exists; pass overwrite=true to replace it, or another path.")
    return json.dumps({"success": True, "path": str(target), "size": len(raw),
                       "sha256": hashlib.sha256(raw).hexdigest(), "filename": record.get("suggestedFilename"),
                       "mime": record.get("mimeType"), "url": record.get("url")}, ensure_ascii=False)


def browser_downloads(save: Optional[str] = None, path: Optional[str] = None, overwrite: bool = False,
                      task_id: Optional[str] = None) -> str:
    """List this session's browser downloads, or save one (id or ``"latest"``) under the
    working directory."""
    try:
        session = client.get_session(task_id)
        save = (save or "").strip()
        if save:
            items = _session_downloads(session)
            if items is not None and save == "latest" and all(r.get("failure") for r in items):
                items = _wait_for_new_download(session)
        else:
            items = _wait_for_new_download(session)
        if items is None:
            return _fail(client.NO_SESSION_ERROR)
        if save:
            return _save_download(session, items, save, path, bool(overwrite), task_id)
        seen = session["seen_downloads"]
        views = []
        for record in items:
            view = _download_view(record)
            view["new"] = record["id"] not in seen
            views.append(view)
        seen.update(r["id"] for r in items)
        result: dict[str, Any] = {"success": True, "downloads": views}
        if not any(v["new"] for v in views):
            result["note"] = (f"No new download within {int(_DOWNLOAD_WAIT_SECONDS)} s. A download is "
                              "listed once the browser has saved it; call again if one is still running.")
        return json.dumps(result, ensure_ascii=False)
    except requests.ConnectionError:
        return _fail(client.connection_error_message())
    except requests.HTTPError as e:
        return _fail(f"Camofox downloads request failed: {e}")
    except Exception as e:
        return _fail(str(e))


# ---- CAPTCHA ----
# A camofox-browser with the captcha plugin (POST /tabs/<id>/solve-captcha) runs a captcha solver
# (CaptchaKraken: a vision model reads each challenge, the browser clicks or drags the answer) on
# the tab's live page, holding the tab meanwhile. The server ends a solve after 120 s by closing the
# tab, and may first wait up to 35 s for the tab's lock, so the client waits longer than both.
_CAPTCHA_SOLVE_TIMEOUT_SECONDS = 180

_CAPTCHA_NEXT = {
    "solved": "The captcha accepted the answer. Submit the page's form now if it has one.",
    "no_captcha": ("No captcha widget is on the page. An invisible reCAPTCHA needs no solve: click the "
                   "page's button, and call browser_solve_captcha again only if a challenge then appears."),
    "failed": "Call browser_solve_captcha once more; if it fails again, report the captcha as the blocker.",
}


def _json_error(resp: Optional[requests.Response]) -> Optional[str]:
    """The server's JSON ``error``, or None when the answer is not camofox JSON (e.g. Express's
    HTML 404 for a route this server does not have)."""
    try:
        data = resp.json() if resp is not None else None
    except ValueError:
        return None
    return str(data.get("error") or data) if isinstance(data, dict) else None


def browser_solve_captcha(task_id: Optional[str] = None) -> str:
    """Solve the captcha on the task's current page in the browser and report the outcome."""
    try:
        session = client.get_session(task_id)
        if not session["tab_id"]:
            return _fail(client.NO_SESSION_ERROR)
        try:
            data = client.post(client.tab_path(session, "solve-captcha"), {"userId": session["user_id"]},
                               timeout=_CAPTCHA_SOLVE_TIMEOUT_SECONDS)
        except requests.HTTPError as e:
            status = e.response.status_code if e.response is not None else None
            detail = _json_error(e.response)
            if status == 404 and detail is None:
                return _fail("This Camofox browser server has no captcha solver.")
            if status in (404, 410):
                session["tab_id"] = None
                return _fail(f"The browser tab is gone ({detail}); the solve may have run out of time. "
                             "Call browser_navigate to open the page again.")
            return _fail(f"Captcha solve request failed ({status}): {detail or e}")
        outcome = data.get("status") or "failed"
        result: dict[str, Any] = {"success": outcome == "solved", "status": outcome, "vendor": data.get("vendor"),
                                  "rounds": data.get("rounds"),
                                  "seconds": round((data.get("durationMs") or 0) / 1000, 1), "url": data.get("url")}
        if data.get("reason"):
            result["reason"] = data["reason"]
        result["next"] = _CAPTCHA_NEXT.get(outcome, _CAPTCHA_NEXT["failed"])
        return json.dumps(result, ensure_ascii=False)
    except requests.ConnectionError:
        return _fail(client.connection_error_message())
    except Exception as e:
        return _fail(str(e))


# ---- Schemas and registry adapters ----

BROWSER_DOWNLOADS = {
    "name": "browser_downloads",
    "description": "Files the browser downloaded: a click on a download link or button, a form whose answer is a file, or a script-started download (also in popup tabs). Without `save`: lists this session's downloads (id, filename, size, mime, url, status), waiting up to 15 s for a new one; a download appears once the browser has saved it. With `save` (an id from the list, or 'latest'): writes that file into the working directory and returns its path, size and sha256. Files over 50 MB are refused; fetch those with curl. Requires browser_navigate first.",
    "parameters": {
        "type": "object",
        "properties": {
            "save": {
                "type": "string",
                "description": "Download id from the list, or 'latest' for the newest complete download. Omit to list."
            },
            "path": {
                "type": "string",
                "description": "Target file or directory, relative to the working directory and inside it. Default: the download's filename in the working directory."
            },
            "overwrite": {
                "type": "boolean",
                "default": False,
                "description": "Replace an existing file at the target."
            }
        },
        "required": []
    }
}

BROWSER_SOLVE_CAPTCHA = {
    "name": "browser_solve_captcha",
    "description": "Solve an image CAPTCHA blocking the current page (reCAPTCHA checkbox or image grid, hCaptcha, GeeTest, Yidun, text captchas, ...) in this browser with a self-hosted vision model: it ticks the captcha checkbox, reads each challenge round and clicks or drags the answer. Takes up to 2 minutes. Returns status 'solved', 'no_captcha' or 'failed' (with reason), the vendor, rounds and seconds. After 'solved', submit the page's form if it has one. Requires browser_navigate first.",
    "parameters": {"type": "object", "properties": {}, "required": []}
}


def handle_downloads(args: dict, **kw: Any) -> str:
    save = args.get("save")
    path = args.get("path")
    return browser_downloads(None if save is None else str(save), None if path is None else str(path),
                             bool(args.get("overwrite", False)), task_id=kw.get("task_id"))


def handle_solve_captcha(args: dict, **kw: Any) -> str:
    return browser_solve_captcha(task_id=kw.get("task_id"))


# ---- Residential proxy ----
# The camofox-browser's residential plugin (../camofox-browser/residential-plugin) gives a userId
# ending in `-residential-<cc>` a browser context through the host's residential proxy, on a sticky
# exit of its own (the proxy session derived from the userId). This tool moves the task's session
# onto such a userId and back. The userId is per TASK (client.task_user_id), so parallel children
# and sessions each get their own residential context, cookies and exit IP, and one task's 'off'
# closes only its own. Offered only when the host has the proxy (RESIDENTIAL_PROXY_URL).

def residential_available() -> bool:
    import re
    return bool(re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", os.environ.get("RESIDENTIAL_PROXY_URL", "")))


def _drop_residential(session: dict[str, Any]) -> None:
    uid = session["user_id"]
    if "-residential-" in uid:
        try:
            client.delete_context(uid)
        except Exception:
            pass


def browser_residential(country: Optional[str], task_id: Optional[str] = None) -> str:
    import re
    try:
        session = client.get_session(task_id)
        direct = session.get("direct_user_id") or session["user_id"]
        want = (country or "").strip().lower()
        if want in ("", "off", "direct", "none"):
            _drop_residential(session)
            session.update(user_id=direct, tab_id=None)
            session.pop("direct_user_id", None)
            return json.dumps({"success": True, "residential": False,
                               "note": "Back on this host's own egress. Call browser_navigate again."})
        if not re.fullmatch(r"[a-z]{2}", want):
            return _fail("country must be a two-letter ISO code (e.g. sg, us, de) or 'off'")
        _drop_residential(session)
        base = direct if client.TASK_CONTEXT_MARK in direct else client.task_user_id(direct, task_id)
        session.update(user_id=f"{base}-residential-{want}", tab_id=None, direct_user_id=direct)
        return json.dumps({"success": True, "residential": True, "country": want.upper(),
                           "note": ("This task's browser now leaves through a residential IP in "
                                    f"{want.upper()} (paid traffic), in a separate browser profile of this task "
                                    "only, without the usual cookies, on an exit IP that stays the same for "
                                    "this task (other tasks get their own). Call browser_navigate to load the "
                                    "page. browser_residential with country 'off' switches back.")})
    except requests.ConnectionError:
        return _fail(client.connection_error_message())
    except Exception as e:
        return _fail(str(e))


# ---- Browser context per task ----
# client.get_session gives delegate_task children and cron runs a context of their own; this tool
# is the explicit switch: 'shared' joins the profile's persistent context (its saved logins, shared
# with the agent's other sessions), 'own' a context of this task only (deleted at task end).

def browser_context(context: Optional[str], task_id: Optional[str] = None) -> str:
    try:
        want = (context or "").strip().lower()
        if want not in ("own", "shared"):
            return _fail("context must be 'own' or 'shared'")
        session = client.get_session(task_id)
        profile = session.get("profile_user_id")
        if not session.get("managed") or not profile:
            return _fail("This browser has no persistent profile context; every task already has its own.")
        _drop_residential(session)
        current = session.get("direct_user_id") or session["user_id"]
        target = profile if want == "shared" else client.task_user_id(profile, task_id)
        if current != target and client.owned_context(current):
            try:
                client.delete_context(current)
            except Exception:
                pass
        session.update(user_id=target, tab_id=None)
        session.pop("direct_user_id", None)
        note = ("This task now browses in the agent's shared profile: its saved logins and cookies, also "
                "used by the agent's other sessions. Changes here (logins, logouts) reach them too."
                if want == "shared" else
                "This task now browses in a context of its own: no saved logins, nothing shared with other "
                "tasks; it is deleted when the task ends.")
        return json.dumps({"success": True, "context": want, "note": note + " Call browser_navigate again."})
    except requests.ConnectionError:
        return _fail(client.connection_error_message())
    except Exception as e:
        return _fail(str(e))


BROWSER_CONTEXT = {
    "name": "browser_context",
    "description": (
        "Choose this task's browser context. Subagents and scheduled jobs start in a context of their "
        "own (no saved logins, nothing shared with parallel tasks). 'shared' joins the agent's persistent "
        "browser profile with its saved logins (use it only when the task needs one of those logins; "
        "other sessions using it see the same cookies). 'own' switches to a private context. Open tabs "
        "of the old context are left; call browser_navigate afterwards."),
    "parameters": {
        "type": "object",
        "properties": {
            "context": {"type": "string", "enum": ["own", "shared"],
                        "description": "'own' (private to this task) or 'shared' (the agent's saved logins)."}
        },
        "required": ["context"]
    }
}


def handle_context(args: dict, **kw: Any) -> str:
    return browser_context(args.get("context"), task_id=kw.get("task_id"))


BROWSER_RESIDENTIAL = {
    "name": "browser_residential",
    "description": (
        "Switch this task's browser onto this host's paid residential proxy (a home IP address in the "
        "given country) or back ('off'). Use ONLY after a site blocked the normal browser (403, bot "
        "wall, 'access denied', region block). It opens a separate browser profile: none of the usual "
        "cookies or logins go along. Never use it to log in to the owner's accounts unless asked. If a "
        "page then fails with the proxy's 'traffic is used up' error, switch it off, do not retry, "
        "and tell the user."),
    "parameters": {
        "type": "object",
        "properties": {
            "country": {
                "type": "string",
                "description": "Two-letter exit country (sg, us, de, ...), or 'off' for the normal egress."
            }
        },
        "required": ["country"]
    }
}


def handle_residential(args: dict, **kw: Any) -> str:
    return browser_residential(args.get("country"), task_id=kw.get("task_id"))
