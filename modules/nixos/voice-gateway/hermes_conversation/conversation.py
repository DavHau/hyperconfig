"""The conversation entity: one POST per turn to the voice-gateway."""

import logging
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
                speech = (await r.json()).get("speech") or ""
        except Exception as e:  # noqa: BLE001 - spoken, not raised
            _LOGGER.warning("voice-gateway failed: %s", e)
            speech = "Sorry, the assistant is not reachable."
        chat_log.async_add_assistant_content_without_tools(
            conversation.AssistantContent(agent_id=user_input.agent_id, content=speech)
        )
        result = conversation.async_get_result_from_chat_log(user_input, chat_log)
        # HA reopens the satellite's microphone after any reply ending in "?"
        # (ChatLog.continue_conversation). In a room with people talking that
        # turns into a loop: background speech becomes the next turn, whose
        # reply ends in "?" again. Every turn starts with the wake word.
        result.continue_conversation = False
        return result
