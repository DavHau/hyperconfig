"""No UI setup: the entry is declared by hyperconfig (../seed.py)."""

from homeassistant.config_entries import ConfigFlow, ConfigFlowResult

from . import DOMAIN


class LocationApiConfigFlow(ConfigFlow, domain=DOMAIN):
    """Refuse every flow; HA only needs this platform to load the entry."""

    VERSION = 1

    async def async_step_user(self, user_input=None) -> ConfigFlowResult:
        return self.async_abort(reason="not_supported")
