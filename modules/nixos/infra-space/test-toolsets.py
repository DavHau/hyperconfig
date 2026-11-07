"""What the infra-space agent may use, as hermes itself resolves it (./test.nix):
run with hermes' venv python in the gateway's environment, as infra. Prints
the toolsets of every platform hermes knows (and acp) and the tool names
the cli platform's agent gets."""

import json

from hermes_cli import plugins

plugins.discover_plugins()

import model_tools  # noqa: E402
from hermes_cli.config import load_config  # noqa: E402
from hermes_cli.platforms import PLATFORMS  # noqa: E402
from hermes_cli.tools_config import _get_platform_tools  # noqa: E402

cfg = load_config()
platforms = {p: sorted(_get_platform_tools(cfg, p)) for p in list(PLATFORMS) + ["acp"]}
disabled = (cfg.get("agent") or {}).get("disabled_toolsets") or []
defs = model_tools.get_tool_definitions(
    enabled_toolsets=platforms["cli"], disabled_toolsets=disabled, quiet_mode=True
)
print(json.dumps({
    "platforms": platforms,
    "tools": sorted(d["function"]["name"] for d in defs),
    "checkpoints": (cfg.get("checkpoints") or {}).get("enabled"),
}))
