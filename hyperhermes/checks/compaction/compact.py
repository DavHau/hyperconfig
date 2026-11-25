"""Run one real context compaction the way an agent session does and print
the outcome as JSON on the last line. Part of ./default.nix.

Usage: compact.py <main-provider> <main-model>

Runs with the agent's environment (the `hermes` shim's: HERMES_HOME of the
home or a profile, HERMES_MANAGED_DIR). That home's .env is loaded as hermes
does at start, and its effective config (the managed overlay included)
decides the auxiliary.compression route. The compressor gets the main
runtime agent/agent_init.py hands it: for anthropic the .env's
ANTHROPIC_BASE_URL and ANTHROPIC_TOKEN (a TeamClaude-style gateway), for
custom the config's model.base_url and OPENAI_API_KEY.
"""

import json
import logging
import os
import sys

logging.basicConfig(level=logging.WARNING)

from hermes_cli.env_loader import load_hermes_dotenv  # noqa: E402

load_hermes_dotenv(hermes_home=os.environ["HERMES_HOME"])

from agent.context_compressor import ContextCompressor  # noqa: E402
from hermes_cli.config import load_config  # noqa: E402

provider, model = sys.argv[1], sys.argv[2]
cfg = load_config()
route = (cfg.get("auxiliary") or {}).get("compression") or {}
if provider == "anthropic":
    base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
    api_key = os.environ.get("ANTHROPIC_TOKEN", "")
    api_mode = "anthropic_messages"
else:
    base_url = (cfg.get("model") or {}).get("base_url", "")
    api_key = os.environ.get("OPENAI_API_KEY", "")
    api_mode = "chat_completions"

compressor = ContextCompressor(
    model=model, provider=provider, base_url=base_url, api_key=api_key, api_mode=api_mode,
    config_context_length=200000, quiet_mode=True,
)

messages = [{"role": "system", "content": "You are a test agent."}]
for i in range(30):
    messages.append({"role": "user", "content": f"Step {i}: please write part {i} of the 4711 report. " + "x" * 400})
    messages.append({"role": "assistant", "content": f"Wrote part {i} of the report to /work/report.md. " + "y" * 400})
messages.append({"role": "user", "content": "What is the status?"})

out = compressor.compress(messages, force=True)
text = "\n".join(str(m.get("content") or "") for m in out)
print(json.dumps({
    "route": {k: route.get(k) for k in ("provider", "model")},
    "before": len(messages),
    "after": len(out),
    "llm_summary": "FAKE-SUMMARY" in text,
    "error": getattr(compressor, "_last_summary_error", None),
}))
