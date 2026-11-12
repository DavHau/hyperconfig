"""Config flow: the gateway URL and the path of the shared-secret file."""

import os

import voluptuous as vol

from homeassistant.config_entries import ConfigFlow, ConfigFlowResult

from .const import CONF_SECRET_FILE, CONF_URL, DOMAIN

SCHEMA = vol.Schema(
    {
        vol.Required(CONF_URL): str,
        vol.Required(CONF_SECRET_FILE, default="/run/secrets/shared/voice-gateway-ha/secret"): str,
    }
)


class HermesConversationFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input=None) -> ConfigFlowResult:
        errors = {}
        if user_input is not None:
            if not await self.hass.async_add_executor_job(os.access, user_input[CONF_SECRET_FILE], os.R_OK):
                errors[CONF_SECRET_FILE] = "unreadable"
            else:
                await self.async_set_unique_id(user_input[CONF_URL])
                self._abort_if_unique_id_configured()
                return self.async_create_entry(title="Hermes", data=user_input)
        return self.async_show_form(step_id="user", data_schema=SCHEMA, errors=errors)
