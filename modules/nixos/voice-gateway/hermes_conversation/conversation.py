"""The conversation entity: one POST per turn to the voice-gateway."""

import logging
import secrets
from pathlib import Path
from typing import Literal

import aiohttp

from homeassistant.components import conversation
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import MATCH_ALL
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from .const import CONF_SECRET_FILE, CONF_URL

_LOGGER = logging.getLogger(__name__)
PARALLEL_UPDATES = 0

# Invisible characters for the per-reply marker below; speech-tts on vit
# strips a trailing run of them before synthesis (tts.py MARKER).
_MARK = ("\u200b", "\u200c", "\u2060", "\u2063")


def uncacheable(speech: str) -> str:
    """Append an invisible random marker so no two replies share a text.

    HA keeps synthesized speech in memory (>= 60 s, not configurable away)
    keyed by the message text. With the soundbar as output speech-tts plays
    the reply itself and hands HA a silent placeholder, so a repeated
    sentence ("Okay, I'm listening.") came from that cache: silent. A
    unique text is the one cache-key part every HA version keeps, and it
    needs no HA internals.
    """
    if not speech.strip():
        return speech
    n = secrets.randbits(24)
    return speech + "".join(_MARK[(n >> (2 * i)) & 3] for i in range(12))


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddConfigEntryEntitiesCallback
) -> None:
    async_add_entities([HermesConversationEntity(entry)])


class HermesConversationEntity(conversation.ConversationEntity, conversation.AbstractConversationAgent):
    _attr_has_entity_name = True
    _attr_name = None

    def __init__(self, entry: ConfigEntry) -> None:
        self.entry = entry
        self._attr_unique_id = entry.entry_id
        self._attr_name = "Hermes"

    @property
    def supported_languages(self) -> list[str] | Literal["*"]:
        return MATCH_ALL

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        conversation.async_set_agent(self.hass, self.entry, self)

    async def async_will_remove_from_hass(self) -> None:
        conversation.async_unset_agent(self.hass, self.entry)
        await super().async_will_remove_from_hass()

    async def _async_handle_message(
        self, user_input: conversation.ConversationInput, chat_log: conversation.ChatLog
    ) -> conversation.ConversationResult:
        secret = await self.hass.async_add_executor_job(
            lambda: Path(self.entry.data[CONF_SECRET_FILE]).read_text().strip()
        )
        # The device id is what trusted mode binds to, so only a satellite's
        # own pipeline run (no HA user in its context) carries one. A turn
        # from the API or the UI names a user, and any HA user (the voice
        # agent's included) could put the satellite's device_id into it:
        # such turns go without one and are never trusted.
        device_id = user_input.device_id if user_input.context.user_id is None else None
        body = {
            "text": user_input.text,
            "conversation_id": user_input.conversation_id,
            "language": user_input.language,
            "device_id": device_id,
        }
        try:
            async with async_get_clientsession(self.hass).post(
                self.entry.data[CONF_URL].rstrip("/") + "/v1/converse",
                json=body,
                headers={"Authorization": f"Bearer {secret}"},
                timeout=aiohttp.ClientTimeout(total=90),
            ) as r:
                r.raise_for_status()
                data = await r.json()
                speech = data.get("speech") or ""
                listen = bool(data.get("continue_conversation"))
        except Exception as e:  # noqa: BLE001 - spoken, not raised
            _LOGGER.warning("voice-gateway failed: %s", e)
            speech, listen = "Sorry, the assistant is not reachable.", False
        chat_log.async_add_assistant_content_without_tools(
            conversation.AssistantContent(agent_id=user_input.agent_id, content=uncacheable(speech))
        )
        result = conversation.async_get_result_from_chat_log(user_input, chat_log)
        # The gateway decides whether the satellite reopens its microphone
        # (the agent asked a real question, or conversation mode is on), not
        # HA's default "reply ends in ?": in a room with people talking that
        # default turned background speech into the next turn, a loop.
        result.continue_conversation = listen and bool(speech.strip())
        return result
