"""The agent's side: load the vault-request plugin from the agent's plugins/ link and call its tool.

usage: tool.py <plugin dir> <json arguments>      prints the tool's JSON result
       tool.py <plugin dir> --register            the tool hermes would register
       tool.py <plugin dir> --vault               the vault's items, metadata only
       tool.py <plugin dir> --hermes              the plugin as hermes' own loader sees it
"""

import importlib.util
import json
import sys

plugin_dir, arg = sys.argv[1:]
if arg == "--hermes":
    from hermes_cli.plugins import discover_plugins, get_plugin_manager
    from tools.registry import registry

    discover_plugins()
    info = [p for p in get_plugin_manager().list_plugins() if p["name"] == "vault-request"]
    seen = {k: info[0][k] for k in ("enabled", "tools", "error")} if info else {}
    print(json.dumps({**seen, "registered": "vault_request" in registry.get_all_tool_names()}))
    sys.exit(0)
spec = importlib.util.spec_from_file_location("vault_request_plugin", f"{plugin_dir}/__init__.py",
                                              submodule_search_locations=[plugin_dir])
mod = importlib.util.module_from_spec(spec)
sys.modules["vault_request_plugin"] = mod
spec.loader.exec_module(mod)

if arg == "--register":
    seen = {}

    class Ctx:
        def register_tool(self, **kw):
            seen.update(name=kw["name"], toolset=kw["toolset"], available=kw["check_fn"]())

    mod.register(Ctx())
    print(json.dumps(seen))
elif arg == "--vault":
    from agent.vault_store import get_vault_store

    print(json.dumps([m.to_dict() for m in get_vault_store().list_items()]))
else:
    print(mod.handle(json.loads(arg)))
