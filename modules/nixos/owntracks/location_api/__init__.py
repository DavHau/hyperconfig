"""Dave's phone location, read-only, for a fixed set of agents.

One GET endpoint, /api/hyper_location, outside HA's own auth: each reader
(an agent) sends its own bearer token, which is checked against the
sha256 of every reader's token (the config entry's `readers`, name ->
hex digest; ../home-assistant.nix seeds it), from one of the entry's `sources`
(addresses or networks; HA's own X-Forwarded-For handling has already
replaced a trusted proxy's address with its client's). A reader gets the tracked entity's
current position and, with ?hours=N (at most MAX_HOURS), its recorded
track, and nothing else of Home Assistant: no other entity, no service,
no HA token.

Answers: 200 JSON, 403 from any other source, 401 for a missing or
unknown token, 503 while no reader is configured or the entity has no
position yet. Every read is logged with the reader's name.
"""

from __future__ import annotations

from datetime import timedelta
import hashlib
import hmac
import ipaddress
import logging
from typing import Any

from aiohttp import web

from homeassistant.components.http import KEY_HASS, HomeAssistantView
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, State
from homeassistant.util import dt as dt_util

_LOGGER = logging.getLogger(__name__)

DOMAIN = "location_api"
URL = "/api/hyper_location"
MAX_HOURS = 48
MAX_POINTS = 500


def _num(value: Any) -> float | None:
    try:
        return None if value is None else float(value)
    except (TypeError, ValueError):
        return None


def _point(state: State) -> dict[str, Any] | None:
    attrs = state.attributes
    lat, lon = _num(attrs.get("latitude")), _num(attrs.get("longitude"))
    if lat is None or lon is None:
        return None
    reported = attrs.get("update_timestamp")
    if hasattr(reported, "isoformat"):
        reported = reported.isoformat()
    return {
        "lat": lat,
        "lon": lon,
        "accuracy_m": _num(attrs.get("gps_accuracy")),
        "zone": state.state,
        # when the phone took the fix (its `tst`), else when HA got it
        "reported_at": reported or state.last_updated.isoformat(),
        "received_at": state.last_updated.isoformat(),
    }


class LocationView(HomeAssistantView):
    url = URL
    name = "api:hyper_location"
    requires_auth = False
    max_body_size = 0

    def __init__(self, entity_id: str, readers: dict[str, str], sources: list[str]) -> None:
        self.entity_id = entity_id
        self.readers = {n: d.lower() for n, d in readers.items() if d}
        self.sources = [ipaddress.ip_network(s, strict=False) for s in sources]

    def _source_ok(self, request: web.Request) -> bool:
        try:
            remote = ipaddress.ip_address(request.remote or "")
        except ValueError:
            return False
        return any(remote in net for net in self.sources)

    def _reader(self, request: web.Request) -> str | None:
        header = request.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme != "Bearer" or not token:
            return None
        digest = hashlib.sha256(token.strip().encode()).hexdigest()
        found = None
        for name, want in self.readers.items():
            # every digest compared, constant time each
            if hmac.compare_digest(digest, want):
                found = name
        return found

    async def get(self, request: web.Request) -> web.Response:
        if not self._source_ok(request):
            return self.json({"error": "forbidden"}, 403)
        if not self.readers:
            return self.json({"error": "no readers configured"}, 503)
        reader = self._reader(request)
        if reader is None:
            return self.json({"error": "unauthorized"}, 401)
        try:
            hours = float(request.query.get("hours", "0"))
        except ValueError:
            return self.json({"error": "hours must be a number"}, 400)
        hours = max(0.0, min(hours, MAX_HOURS))

        hass: HomeAssistant = request.app[KEY_HASS]
        state = hass.states.get(self.entity_id)
        current = _point(state) if state else None
        _LOGGER.info("location read by %s (hours=%s)", reader, hours)
        if current is None:
            return self.json({"error": "no position yet", "entity_id": self.entity_id}, 503)

        now = dt_util.utcnow()
        attrs = state.attributes
        current |= {
            "age_s": round((now - state.last_updated).total_seconds()),
            "battery": _num(attrs.get("battery_level")),
            "velocity_kmh": _num(attrs.get("velocity")),
        }
        body: dict[str, Any] = {
            "entity_id": self.entity_id,
            "now": now.isoformat(),
            "current": current,
        }
        if hours > 0:
            body["history"] = await self._history(hass, now - timedelta(hours=hours))
        return self.json(body, headers={"Cache-Control": "no-store"})

    async def _history(self, hass: HomeAssistant, start) -> list[dict[str, Any]]:
        try:
            from homeassistant.components.recorder import get_instance, history
        except ImportError:
            return []

        def query() -> list[State]:
            states = history.get_significant_states(
                hass,
                start,
                entity_ids=[self.entity_id],
                significant_changes_only=False,
                include_start_time_state=False,
            )
            return states.get(self.entity_id, [])

        try:
            states = await get_instance(hass).async_add_executor_job(query)
        except Exception:  # noqa: BLE001 - recorder off or busy: current only
            _LOGGER.exception("history query failed")
            return []
        points = [p for s in states if isinstance(s, State) and (p := _point(s))]
        return points[-MAX_POINTS:]


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    hass.http.register_view(
        LocationView(
            entry.data["entity_id"],
            dict(entry.data.get("readers") or {}),
            list(entry.data.get("sources") or []),
        )
    )
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    # aiohttp routes cannot be removed; a reload needs a restart
    return False
