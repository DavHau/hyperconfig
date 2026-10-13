"""Benchmark target sets and the hard exclusion list.

The sites live in a targets file that is kept out of git (JSON):

  {"smoke_url": "https://...",
   "targets": [{"name": ..., "url": ..., "source": ..., "settle_s": 6, "reason": "optional"}],
   "exclude": [{"host_regex": ..., "reason": ...}]}

Every target is a public GET page. The built-in exclusions plus the file's
are applied to targets at plan time and to every main-frame
navigation/redirect at load time.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

SMOKE_SOURCE = "smoke"  # reserved: marks the fingerprint load of `web-bench smoke`
MAX_SETTLE_S = 60.0

_SEARCH = "search engine"

# (host regex, reason). Infrastructure that is never benchmarked, whatever
# the targets file says; checked before the file's own exclusions.
BUILTIN_EXCLUDE: tuple[tuple[str, str], ...] = (
    (r"(^|\.)github\.com$", "GitHub (hard exclusion)"),
    (r"(^|\.)google(\.[a-z]{2,3}){1,2}$", _SEARCH),
    (r"(^|\.)bing\.com$", _SEARCH),
    (r"(^|\.)duckduckgo\.com$", _SEARCH),
    (r"(^|\.)brave\.com$", _SEARCH),
    (r"(^|\.)startpage\.com$", _SEARCH),
    (r"(^|\.)mojeek\.(com|co\.uk)$", _SEARCH),
    (r"(^|\.)qwant\.com$", _SEARCH),
    (r"(^|\.)yahoo(\.[a-z]{2,3}){1,2}$", _SEARCH),
    (r"(^|\.)ecosia\.org$", _SEARCH),
    (r"(^|\.)yandex\.[a-z]{2,3}$", _SEARCH),
    (r"(^|\.)baidu\.com$", _SEARCH),
)

# Pages behind these path segments are not public; never plan them.
_PRIVATE_PATH = re.compile(r"/(login|log-in|signin|sign-in|signup|account|auth|checkout|cart)(/|$|\?)", re.I)


class TargetsError(ValueError):
    pass


@dataclass(frozen=True)
class Target:
    name: str
    url: str
    source: str
    reason: str = ""
    settle_s: float = 6.0


@dataclass(frozen=True)
class TargetSet:
    targets: tuple[Target, ...]
    exclude: tuple[tuple[str, str], ...]  # the file's (host regex, reason), after BUILTIN_EXCLUDE
    smoke_url: str

    def excluded(self, url: str) -> str | None:
        return excluded(url, self.exclude)

    def split(self) -> tuple[list[Target], list[tuple[Target, str]]]:
        """(planned targets, [(excluded target, reason)])."""
        keep: list[Target] = []
        dropped: list[tuple[Target, str]] = []
        for t in self.targets:
            why = self.excluded(t.url)
            if why:
                dropped.append((t, why))
            elif t.url.startswith("https://"):
                keep.append(t)
            else:
                dropped.append((t, "not https"))
        return keep, dropped


def host(url: str) -> str:
    return (urlsplit(url).hostname or "").lower().rstrip(".")


def excluded(url: str, extra: tuple[tuple[str, str], ...] | list = ()) -> str | None:
    """Reason the URL must not be loaded, or None; `extra` are further (host regex, reason) rules."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        return f"scheme {parts.scheme or '-'} not allowed"
    if parts.username or parts.password:
        return "credentials in URL"
    if _PRIVATE_PATH.search(parts.path):
        return "non-public path"
    h = host(url)
    for rx, why in (*BUILTIN_EXCLUDE, *extra):
        if re.search(rx, h):
            return why
    return None


def _fields(obj, where: str, required: set[str], optional: set[str] = frozenset()) -> dict:
    if not isinstance(obj, dict):
        raise TargetsError(f"{where}: expected an object")
    missing, unknown = required - obj.keys(), obj.keys() - required - optional
    if missing or unknown:
        raise TargetsError(f"{where}: missing {sorted(missing)}, unknown {sorted(unknown)}")
    return obj


def _str(v, where: str) -> str:
    if not isinstance(v, str) or not v.strip():
        raise TargetsError(f"{where}: expected a non-empty string")
    return v


def parse(data) -> TargetSet:
    top = _fields(data, "targets file", {"smoke_url", "targets", "exclude"})
    if not isinstance(top["exclude"], list):
        raise TargetsError("exclude: expected a list")
    exclude = []
    for i, e in enumerate(top["exclude"]):
        e = _fields(e, f"exclude[{i}]", {"host_regex", "reason"})
        rx = _str(e["host_regex"], f"exclude[{i}].host_regex")
        try:
            re.compile(rx)
        except re.error as err:
            raise TargetsError(f"exclude[{i}].host_regex: {err}") from None
        exclude.append((rx, _str(e["reason"], f"exclude[{i}].reason")))
    if not isinstance(top["targets"], list) or not top["targets"]:
        raise TargetsError("targets: expected a non-empty list")
    targets, names = [], set()
    for i, t in enumerate(top["targets"]):
        t = _fields(t, f"targets[{i}]", {"name", "url", "source", "settle_s"}, {"reason"})
        name = _str(t["name"], f"targets[{i}].name")
        if name in names:
            raise TargetsError(f"targets[{i}]: duplicate name {name!r}")
        names.add(name)
        source = _str(t["source"], f"targets[{i}].source")
        if source == SMOKE_SOURCE:
            raise TargetsError(f"targets[{i}].source: {SMOKE_SOURCE!r} is reserved")
        settle = t["settle_s"]
        if isinstance(settle, bool) or not isinstance(settle, (int, float)) or not 0 <= settle <= MAX_SETTLE_S:
            raise TargetsError(f"targets[{i}].settle_s: expected a number in [0, {MAX_SETTLE_S:g}]")
        reason = _str(t["reason"], f"targets[{i}].reason") if "reason" in t else ""
        targets.append(Target(name, _str(t["url"], f"targets[{i}].url"), source, reason, float(settle)))
    smoke_url = _str(top["smoke_url"], "smoke_url")
    if not smoke_url.startswith("https://") or excluded(smoke_url, exclude):
        raise TargetsError(f"smoke_url: {smoke_url} is not an allowed https URL")
    return TargetSet(tuple(targets), tuple(exclude), smoke_url)


def load(path: Path) -> TargetSet:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as err:
        raise TargetsError(f"{path}: {err}") from None
    try:
        return parse(data)
    except TargetsError as err:
        raise TargetsError(f"{path}: {err}") from None
