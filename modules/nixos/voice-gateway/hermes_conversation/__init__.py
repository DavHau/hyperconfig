"""Hermes conversation agent: forwards Assist turns to som's voice-gateway.

The gateway (hyperconfig modules/nixos/voice-gateway) decides which hermes
agent answers (the untrusted `voice` agent, or the infra agent once Dave
unlocked trusted mode) and returns the text to speak. This integration only
carries {text, conversation_id, language, device_id} there with a shared
secret read from a file (a clan var on this host), and hands back the reply.
"""

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant

PLATFORMS = [Platform.CONVERSATION]


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
