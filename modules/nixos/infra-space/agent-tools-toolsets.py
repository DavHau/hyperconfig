"""The infra agent's toolsets and plugins as hermes itself resolves them
(./agent-tools-test.nix): run with the installed hermes' venv python, as
infra, in the gateway's environment (its HERMES_HOME, HERMES_BUNDLED_PLUGINS,
CAMOFOX_* there or in its .env). Prints, per platform, the toolsets _get_platform_tools gives,
the tool names the cli agent gets, and the plugins hermes discovered."""

import json
import os

from hermes_cli import plugins

plugins.discover_plugins()

import model_tools  # noqa: E402
from hermes_cli.config import load_config, load_env  # noqa: E402
from hermes_cli.tools_config import _get_platform_tools  # noqa: E402

cfg = load_config()
platforms = {p: sorted(_get_platform_tools(cfg, p)) for p in ["cli", "telegram", "cron", "acp", "api_server"]}
disabled = (cfg.get("agent") or {}).get("disabled_toolsets") or []
defs = model_tools.get_tool_definitions(enabled_toolsets=platforms["cli"], disabled_toolsets=disabled, quiet_mode=True)
print(json.dumps({
    "platforms": platforms,
    "tools": sorted(d["function"]["name"] for d in defs),
    "plugins": sorted(p.get("name") or p.get("key") or "" for p in plugins.get_plugin_manager().list_plugins()),
    # names only: the process environment and hermes' .env (where secretEnv lands)
    "camofox_env": sorted({k for k in [*os.environ, *load_env()] if k.startswith("CAMOFOX")}),
    "hermes_home": os.environ.get("HERMES_HOME"),
}))
