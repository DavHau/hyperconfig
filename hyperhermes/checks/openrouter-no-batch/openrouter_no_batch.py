"""Offline check of hermes-openrouter-no-batch.patch: OpenRouter `:batch` ids (async Batch API)
are never offered or used for chat.

A fake live OpenRouter catalog carrying the four real deepseek-v4.1-flash ids (two of them
`:batch`), fake keys, no network:
- fetch_openrouter_models / model_ids list both chat ids and neither :batch id (the regression
  Dave saw: deepseek/deepseek-v4.1-flash-1017 must be there on its own);
- drop_unofferable_model_ids strips :batch from OpenRouter-routed rows only (an unrelated custom
  provider's id ending in :batch is kept);
- the OpenRouter credential fingerprint changes, so a provider_models_cache.json row cached with
  :batch ids is refetched;
- an AIAgent built for openrouter + `...:batch` runs the plain id, its fallback chain too; /model
  and auxiliary clients map it; a non-OpenRouter provider's `:batch` id is left alone.
Run with HERMES_HOME pointing at an empty directory.
"""

import os
from pathlib import Path
from unittest.mock import MagicMock, patch

import yaml

home = Path(os.environ["HERMES_HOME"])
OR_KEY = "sk-or-v1-0123456789abcdef0123456789abcdef"
os.environ["OPENROUTER_API_KEY"] = OR_KEY
for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"):
    os.environ.pop(k, None)
(home / "config.yaml").write_text(yaml.safe_dump({
    "model": {"provider": "openrouter", "default": "deepseek/deepseek-v4.1-flash"},
    "model_catalog": {"openrouter_all_models": True},
    "providers": {"batchy": {"base_url": "https://llm.example.test/v1", "api_key": "x"}}}))

import hermes_cli.models as m  # noqa: E402
import hermes_cli.model_catalog as mc  # noqa: E402

IDS = ["deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash:batch",
       "deepseek/deepseek-v4.1-flash-1017", "deepseek/deepseek-v4.1-flash-1017:batch", "openai/gpt-6"]
PAID = {"prompt": "0.000001", "completion": "0.000002"}
LIVE = [{"id": i, "supported_parameters": ["tools"], "pricing": PAID} for i in IDS]
m._fetch_live_catalog_index = lambda url, timeout, opener: (list(LIVE), {i["id"]: i for i in LIVE})
mc.get_curated_openrouter_models = lambda: [("deepseek/deepseek-v4.1-flash", "")]
m.get_preferred_silent_default_model = lambda provider="openrouter": ""

failures = []


def check(name, got, want):
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"\n  got:  {got!r}\n  want: {want!r}"))
    if not ok:
        failures.append(name)


PLAIN = ["deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash-1017", "openai/gpt-6"]
check("catalog: :batch ids dropped, both chat ids kept",
      [mid for mid, _ in m.fetch_openrouter_models(force_refresh=True)], PLAIN)
check("model_ids: no :batch", [x for x in m.model_ids() if x.endswith(":batch")], [])

from hermes_cli.models_validate import drop_unofferable_model_ids  # noqa: E402
rows = [{"slug": "openrouter", "models": list(IDS), "total_models": 5,
         "featured_models": ["deepseek/deepseek-v4.1-flash-1017:batch", "openai/gpt-6"]},
        {"slug": "custom:x", "api_url": "https://openrouter.ai/api/v1", "models": ["a/b:batch", "a/b"]},
        {"slug": "batchy", "api_url": "https://llm.example.test/v1", "models": ["local:batch"]}]
drop_unofferable_model_ids(rows)
check("picker rows: OpenRouter-routed rows lose :batch, others keep it",
      [r["models"] for r in rows], [PLAIN, ["a/b"], ["local:batch"]])
check("picker rows: total_models and featured_models follow",
      (rows[0]["total_models"], rows[0]["featured_models"]), (3, ["openai/gpt-6"]))
import hashlib  # noqa: E402
fp = m._credential_fingerprint("openrouter")
with patch.object(hashlib, "blake2b", wraps=hashlib.blake2b) as h:
    m._credential_fingerprint("openrouter")
check("OpenRouter cache fingerprint carries the no-batch marker (old cache rows refetched)",
      b"openrouter_no_batch=1" in h.call_args.args[0], True)
check("fingerprint is stable", m._credential_fingerprint("openrouter"), fp)


def make_agent(**kw):
    from run_agent import AIAgent
    tool_defs = [{"type": "function", "function": {"name": "web_search", "description": "s",
                                                   "parameters": {"type": "object", "properties": {}}}}]
    with patch("model_tools.get_tool_definitions", return_value=tool_defs), \
         patch("model_tools.check_toolset_requirements", return_value={}), \
         patch("agent.process_bootstrap.OpenAI", return_value=MagicMock()):
        return AIAgent(quiet_mode=True, skip_context_files=True, skip_memory=True, api_key=OR_KEY, **kw)


agent = make_agent(provider="openrouter", base_url="https://openrouter.ai/api/v1",
                   model="deepseek/deepseek-v4.1-flash-1017:batch",
                   fallback_model=[{"provider": "openrouter", "model": "deepseek/deepseek-v4.1-flash:batch"},
                                   {"provider": "openrouter", "model": "openai/gpt-6"}])
check("AIAgent(openrouter, ...:batch) runs the plain id", (agent.provider, agent.model),
      ("openrouter", "deepseek/deepseek-v4.1-flash-1017"))
check("fallback chain: :batch entry mapped, others kept",
      [(f["provider"], f["model"]) for f in agent._fallback_chain],
      [("openrouter", "deepseek/deepseek-v4.1-flash"), ("openrouter", "openai/gpt-6")])

agent = make_agent(provider="batchy", base_url="https://llm.example.test/v1", model="local:batch")
check("non-OpenRouter provider: a :batch id is left alone", agent.model, "local:batch")

from hermes_cli.model_switch import switch_model  # noqa: E402
res = switch_model("deepseek/deepseek-v4.1-flash-1017:batch", current_provider="openrouter",
                   current_model="deepseek/deepseek-v4.1-flash", current_base_url="https://openrouter.ai/api/v1",
                   current_api_key=OR_KEY)
check("/model ...:batch on OpenRouter switches to the plain id",
      (res.success, res.target_provider, res.new_model), (True, "openrouter", "deepseek/deepseek-v4.1-flash-1017"))

from agent.auxiliary_client import resolve_provider_client  # noqa: E402
with patch("agent.auxiliary_client.OpenAI", return_value=MagicMock()):
    _client, model = resolve_provider_client("openrouter", "deepseek/deepseek-v4.1-flash:batch")
check("auxiliary: openrouter ...:batch resolves to the plain id", model, "deepseek/deepseek-v4.1-flash")

if failures:
    raise SystemExit(f"{len(failures)} check(s) failed: {failures}")
print("all checks passed")
