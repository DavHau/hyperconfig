"""Offline check of model_catalog.openrouter_exclude_native (hermes-openrouter-exclude-native.patch).

A fake live OpenRouter catalog, fake keys, no network. With [anthropic] and an Anthropic key:
- OpenRouter's anthropic/* rows are gone from fetch_openrouter_models / model_ids and picker rows;
- resolve_runtime_provider(openrouter, anthropic/claude-opus-5.5) resolves to the anthropic provider;
- delegation.provider=openrouter + delegation.model=anthropic/claude-opus-5.5 (how fpv's subagents
  ended up on OpenRouter) builds the child on anthropic, and so does an OpenRouter parent's child
  with a Claude model override;
- an AIAgent built for openrouter + Claude is constructed on anthropic, its OpenRouter Claude
  fallback entry too;
- auxiliary clients and /model switches go native;
- model-less resolve_runtime_provider(requested=openrouter) (image/video gen, credits display) keeps
  OpenRouter's key/URL even when the main model is Claude on anthropic;
- OpenRouter ids map to native ids: :<variant> dropped, -fast -> base model + speed fast,
  ~...-latest and undated short ids through _PROVIDER_MODELS["anthropic"];
- a named custom provider at openrouter.ai counts as OpenRouter.
Without the Anthropic key nothing changes. Run with HERMES_HOME pointing at an empty directory.
"""

import os
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import yaml

home = Path(os.environ["HERMES_HOME"])
OR_KEY = "sk-or-fake-0123456789abcdef"
ANT_KEY = "sk-ant-api03-fake-0123456789abcdef"
os.environ["OPENROUTER_API_KEY"] = OR_KEY
for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"):
    os.environ.pop(k, None)

import hermes_cli.models as m  # noqa: E402
import hermes_cli.model_catalog as mc  # noqa: E402
import hermes_cli.openrouter_native as orn  # noqa: E402
import agent.anthropic_credentials as ac  # noqa: E402

TOOLS = ["tools"]
PAID = {"prompt": "0.000001", "completion": "0.000002"}
LIVE = [{"id": i, "supported_parameters": TOOLS, "pricing": PAID}
        for i in ("anthropic/claude-opus-5.5", "anthropic/claude-sonnet-5", "deepseek/deepseek-v4", "openai/gpt-6")]
m._fetch_live_catalog_index = lambda url, timeout, opener: (list(LIVE), {i["id"]: i for i in LIVE})
mc.get_curated_openrouter_models = lambda: [("anthropic/claude-opus-5.5", ""), ("deepseek/deepseek-v4", "")]
m.get_preferred_silent_default_model = lambda provider="openrouter": ""
ac.read_claude_code_credentials = lambda *a, **k: None
ac._resolve_anthropic_pool_token = lambda *a, **k: None

failures = []
bump = [0]


def check(name, got, want):
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"\n  got:  {got!r}\n  want: {want!r}"))
    if not ok:
        failures.append(name)


def setup(*, exclude=("anthropic",), anthropic_key=True):
    cfg = {"model": {"provider": "openrouter", "default": "deepseek/deepseek-v4"},
           "model_catalog": {"openrouter_all_models": True}}
    if exclude is not None:
        cfg["model_catalog"]["openrouter_exclude_native"] = list(exclude)
    (home / "config.yaml").write_text(yaml.safe_dump(cfg))
    bump[0] += 10
    t = 2_000_000_000 + bump[0]
    os.utime(home / "config.yaml", (t, t))
    if anthropic_key:
        os.environ["ANTHROPIC_API_KEY"] = ANT_KEY
    else:
        os.environ.pop("ANTHROPIC_API_KEY", None)
    m._openrouter_catalog_cache = None
    m._openrouter_all_catalog_cache = None
    orn.reset_cache()


def catalog_ids():
    return [mid for mid, _ in m.fetch_openrouter_models(force_refresh=True)]


def parent():
    return SimpleNamespace(
        provider="openrouter", model="deepseek/deepseek-v4", base_url="https://openrouter.ai/api/v1", api_key=OR_KEY,
        api_mode="chat_completions", requested_provider="openrouter", acp_command=None, acp_args=[],
        reasoning_config=None, request_overrides={}, _fallback_chain=[], providers_allowed=None,
        providers_ignored=None, providers_order=None, provider_sort=None, provider_require_parameters=False,
        provider_data_collection=None, openrouter_min_coding_score=None, max_tokens=None, capabilities={})


def child_runtime(model, creds=None):
    from tools.delegate_tool_config import _resolve_child_runtime
    creds = creds or {"provider": "openrouter", "base_url": "https://openrouter.ai/api/v1", "api_key": OR_KEY,
                      "api_mode": None}
    return _resolve_child_runtime(
        parent(), {}, OR_KEY, model=model, override_provider=creds["provider"], override_base_url=creds["base_url"],
        override_api_key=creds["api_key"], override_api_mode=creds["api_mode"], override_acp_command=None,
        override_acp_args=None)


def make_agent(**kw):
    from run_agent import AIAgent
    tool_defs = [{"type": "function", "function": {"name": "web_search", "description": "s",
                                                   "parameters": {"type": "object", "properties": {}}}}]
    with patch("model_tools.get_tool_definitions", return_value=tool_defs), \
         patch("model_tools.check_toolset_requirements", return_value={}), \
         patch("agent.process_bootstrap.OpenAI", return_value=MagicMock()), \
         patch("agent.anthropic_adapter.build_anthropic_client", return_value=MagicMock()):
        return AIAgent(quiet_mode=True, skip_context_files=True, skip_memory=True,
                       base_url="https://openrouter.ai/api/v1", api_key=OR_KEY, **kw)


from hermes_cli.runtime_provider import resolve_runtime_provider  # noqa: E402
from hermes_cli.models_validate import drop_unofferable_model_ids  # noqa: E402
from tools.delegate_tool_config import _resolve_delegation_credentials  # noqa: E402

# ── with an Anthropic credential ──
setup()
check("catalog: anthropic/* dropped", catalog_ids(), ["deepseek/deepseek-v4", "openai/gpt-6"])
check("model_ids: anthropic/* dropped", [x for x in m.model_ids() if x.startswith("anthropic/")], [])
rows = [{"slug": "openrouter", "models": ["anthropic/claude-opus-5.5", "openai/gpt-6"]},
        {"slug": "anthropic", "models": ["claude-opus-5-5"]}]
drop_unofferable_model_ids(rows)
check("picker rows: openrouter row filtered, anthropic row kept",
      [r["models"] for r in rows], [["openai/gpt-6"], ["claude-opus-5-5"]])

rt = resolve_runtime_provider(requested="openrouter", target_model="anthropic/claude-opus-5.5")
check("runtime resolution: openrouter Claude -> anthropic",
      (rt["provider"], rt["api_mode"], rt["model"], rt["api_key"]),
      ("anthropic", "anthropic_messages", "claude-opus-5-5", ANT_KEY))
check("runtime resolution: other OpenRouter models untouched",
      resolve_runtime_provider(requested="openrouter", target_model="deepseek/deepseek-v4")["provider"], "openrouter")

creds = _resolve_delegation_credentials({"provider": "openrouter", "model": "anthropic/claude-opus-5.5"}, parent())
rt = child_runtime(creds["model"], creds)
check("fpv path: delegation.provider=openrouter + anthropic/claude-opus-5.5 child on anthropic",
      (rt["provider"], rt["api_key"]), ("anthropic", ANT_KEY))
rt = child_runtime("anthropic/claude-opus-5.5")
check("delegate_task(provider=openrouter, model=anthropic/claude-opus-5.5) child on anthropic",
      (rt["provider"], rt["model"], rt["api_mode"], "openrouter" in str(rt["base_url"])),
      ("anthropic", "claude-opus-5-5", "anthropic_messages", False))

agent = make_agent(provider="openrouter", model="anthropic/claude-opus-5.5",
                   fallback_model=[{"provider": "openrouter", "model": "anthropic/claude-sonnet-5"},
                                   {"provider": "openrouter", "model": "openai/gpt-6"}])
check("AIAgent(openrouter, Claude) built on anthropic", (agent.provider, agent.model, agent.api_mode),
      ("anthropic", "claude-opus-5-5", "anthropic_messages"))
check("fallback chain: OpenRouter Claude entry native, others kept",
      [(f["provider"], f["model"]) for f in agent._fallback_chain],
      [("anthropic", "claude-sonnet-5"), ("openrouter", "openai/gpt-6")])

from agent.auxiliary_client import resolve_provider_client  # noqa: E402
with patch("agent.anthropic_adapter.build_anthropic_client", return_value=MagicMock()):
    client, _ = resolve_provider_client("openrouter", "anthropic/claude-opus-5.5")
check("auxiliary: openrouter Claude client is not OpenRouter",
      client is not None and "openrouter" not in str(getattr(client, "base_url", "")), True)

from hermes_cli.model_switch import switch_model  # noqa: E402
res = switch_model("anthropic/claude-opus-5.5", current_provider="openrouter", current_model="deepseek/deepseek-v4",
                   current_base_url="https://openrouter.ai/api/v1", current_api_key=OR_KEY)
check("/model anthropic/claude-opus-5.5 on OpenRouter switches to anthropic",
      (res.target_provider, res.new_model), ("anthropic", "claude-opus-5-5"))

# ── model-less OpenRouter callers keep OpenRouter (main model Claude on anthropic) ──
cfg = yaml.safe_load((home / "config.yaml").read_text())
cfg["model"] = {"provider": "anthropic", "default": "claude-opus-5-5"}
cfg["providers"] = {"orproxy": {"base_url": "https://openrouter.ai/api/v1", "api_key": OR_KEY}}
(home / "config.yaml").write_text(yaml.safe_dump(cfg))
bump[0] += 10
os.utime(home / "config.yaml", (2_000_000_000 + bump[0],) * 2)
orn.reset_cache()
rt = resolve_runtime_provider(requested="openrouter")
check("model-less openrouter resolution stays on OpenRouter", (rt["provider"], rt["api_key"], "openrouter.ai" in rt["base_url"]),
      ("openrouter", OR_KEY, True))
import importlib  # noqa: E402
img = importlib.import_module("plugins.image_gen.openrouter")._build_providers()[0]
check("image_gen OpenRouter credentials", img._credentials(), (OR_KEY, "https://openrouter.ai/api/v1"))
vid_mod = importlib.import_module("plugins.video_gen.openrouter")
vid = [c for c in vars(vid_mod).values() if isinstance(c, type) and "_credentials" in vars(c)][0]()
check("video_gen OpenRouter credentials", vid._credentials(), (OR_KEY, "https://openrouter.ai/api/v1"))

# ── main model Claude on OpenRouter: model-less named callers still keep OpenRouter ──
cfg["model"] = {"provider": "openrouter", "default": "anthropic/claude-opus-5.5"}
(home / "config.yaml").write_text(yaml.safe_dump(cfg))
bump[0] += 10
os.utime(home / "config.yaml", (2_000_000_000 + bump[0],) * 2)
orn.reset_cache()
rt = resolve_runtime_provider()
check("main runtime (requested unset), model.default Claude on OpenRouter -> anthropic",
      (rt["provider"], rt["model"], rt["api_key"]), ("anthropic", "claude-opus-5-5", ANT_KEY))
rt = resolve_runtime_provider(requested="openrouter")
check("Claude main model: model-less requested=openrouter stays on OpenRouter",
      (rt["provider"], rt["api_key"], "openrouter.ai" in rt["base_url"]), ("openrouter", OR_KEY, True))
rt = resolve_runtime_provider(requested="openrouter", explicit_base_url="https://openrouter.ai/api/v1",
                              explicit_api_key=OR_KEY, target_model="anthropic/claude-opus-5.5")
check("explicit OpenRouter key/base_url: never rewritten", (rt["provider"], rt["api_key"]), ("openrouter", OR_KEY))
img = importlib.import_module("plugins.image_gen.openrouter")._build_providers()[0]
check("Claude main model: image_gen OpenRouter credentials", img._credentials(), (OR_KEY, "https://openrouter.ai/api/v1"))
vid = [c for c in vars(vid_mod).values() if isinstance(c, type) and "_credentials" in vars(c)][0]()
check("Claude main model: video_gen OpenRouter credentials", vid._credentials(), (OR_KEY, "https://openrouter.ai/api/v1"))
import agent.account_usage as au  # noqa: E402
for args in ((None, None), ("https://openrouter.ai/api/v1", OR_KEY)):
    seen = []

    class _Resp:
        def raise_for_status(self):
            pass

        def json(self):
            return {"data": {}}

    class _Client:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def get(self, url, headers=None):
            seen.append((url, (headers or {}).get("Authorization")))
            return _Resp()

    with patch.object(au.httpx, "Client", _Client):
        au._fetch_openrouter_account_usage(*args)
    check(f"Claude main model: account_usage credits on OpenRouter {args[0] is not None and 'explicit' or 'default'}",
          {(u.split("/api/v1/")[0], a) for u, a in seen}, {("https://openrouter.ai", f"Bearer {OR_KEY}")})
check("named custom provider at openrouter.ai is an OpenRouter route", orn.is_openrouter_route("orproxy"), True)
check("named custom provider at openrouter.ai: Claude goes native",
      orn.native_target("orproxy", "anthropic/claude-opus-5.5"), ("anthropic", "claude-opus-5-5"))

# ── id mapping ──
for mid, want in [
    ("anthropic/claude-opus-5.5:thinking", ("claude-opus-5-5", {})),
    ("anthropic/claude-sonnet-5:beta", ("claude-sonnet-5", {})),
    ("anthropic/claude-opus-5.5:nitro", ("claude-opus-5-5", {})),
    ("anthropic/claude-opus-5.5:floor", ("claude-opus-5-5", {})),
    ("anthropic/claude-sonnet-4.6:extended", ("claude-sonnet-4-6", {})),
    ("anthropic/claude-opus-5-fast", ("claude-opus-5", {"speed": "fast"})),
    ("anthropic/claude-opus-4.8-fast", ("claude-opus-4-8", {"speed": "fast"})),
    ("~anthropic/claude-opus-latest", ("claude-opus-5-5", {})),
    ("~anthropic/claude-sonnet-latest", ("claude-sonnet-5", {})),
    ("anthropic/claude-sonnet-4", ("claude-sonnet-4-20250514", {})),
    ("anthropic/claude-haiku-4.5", ("claude-haiku-4-5-20251001", {})),
    ("anthropic/claude-3-7-sonnet", ("claude-3-7-sonnet", {})),  # not listed: base mapping, logged
]:
    check(f"id mapping {mid}", orn.native_target_full("openrouter", mid)[1:], want)
rt = resolve_runtime_provider(requested="openrouter", target_model="anthropic/claude-opus-5-fast")
check("runtime resolution: -fast id -> base model with speed fast",
      (rt["provider"], rt["model"], (rt.get("request_overrides") or {}).get("speed")), ("anthropic", "claude-opus-5", "fast"))
rt = child_runtime("anthropic/claude-opus-4.8-fast")
check("delegate child: -fast id -> base model, fast overrides carried",
      (rt["provider"], rt["model"], rt.get("native_request_overrides")), ("anthropic", "claude-opus-4-8", {"speed": "fast"}))
agent = make_agent(provider="openrouter", model="anthropic/claude-opus-5-fast")
check("AIAgent(openrouter, -fast) built on anthropic with speed fast",
      (agent.provider, agent.model, agent.request_overrides.get("speed")), ("anthropic", "claude-opus-5", "fast"))

# ── a -fast id's speed stays with that model: fallback and /model drop it ──
from agent.chat_completion_helpers import build_api_kwargs, try_activate_fallback  # noqa: E402
from agent.fast_mode import effective_request_overrides  # noqa: E402
MSG = [{"role": "user", "content": "hi"}]


def wire_speed(kw):
    return kw.get("speed") or (kw.get("extra_body") or {}).get("speed")


agent = make_agent(provider="openrouter", model="anthropic/claude-opus-5-fast",
                   fallback_model=[{"provider": "openrouter", "model": "openai/gpt-6"}])
with patch("agent.anthropic_adapter.build_anthropic_client", return_value=MagicMock()):
    check("-fast primary: speed fast on the wire", wire_speed(build_api_kwargs(agent, MSG, None)), "fast")
with patch("agent.auxiliary_client.OpenAI", return_value=MagicMock()):
    activated = try_activate_fallback(agent)
check("-fast primary -> openrouter openai/gpt-6 fallback: no speed",
      (activated, agent.provider, agent.model, "speed" in effective_request_overrides(agent),
       wire_speed(build_api_kwargs(agent, MSG, None))), (True, "openrouter", "openai/gpt-6", False, None))
agent = make_agent(provider="openrouter", model="anthropic/claude-opus-5-fast")
with patch("agent.auxiliary_client.OpenAI", return_value=MagicMock()), \
     patch("agent.process_bootstrap.OpenAI", return_value=MagicMock()):
    agent.switch_model("openai/gpt-6", "openrouter", api_key=OR_KEY, base_url="https://openrouter.ai/api/v1",
                       api_mode="chat_completions")
check("-fast primary, switch_model to openai/gpt-6: no speed",
      (agent.model, "speed" in (agent.request_overrides or {}), wire_speed(build_api_kwargs(agent, MSG, None))),
      ("openai/gpt-6", False, None))
agent = make_agent(provider="openrouter", model="deepseek/deepseek-v4", request_overrides={"speed": "fast"})
check("stray speed on a non-Anthropic route is never sent", "speed" in effective_request_overrides(agent), False)

# ── main agent already on anthropic with an OpenRouter-style configured id (gateway/cron/CLI) ──
for mid, want, speed in [
    ("anthropic/claude-opus-5-fast", "claude-opus-5", "fast"),
    ("anthropic/claude-opus-5.5:thinking", "claude-opus-5-5", None),
    ("~anthropic/claude-opus-latest", "claude-opus-5-5", None),
    ("anthropic/claude-sonnet-4", "claude-sonnet-4-20250514", None),
    ("claude-sonnet-4", "claude-sonnet-4-20250514", None),
    ("claude-opus-5-5", "claude-opus-5-5", None),
]:
    with patch("model_tools.get_tool_definitions", return_value=[]), \
         patch("model_tools.check_toolset_requirements", return_value={}), \
         patch("agent.anthropic_adapter.build_anthropic_client", return_value=MagicMock()):
        from run_agent import AIAgent
        a = AIAgent(quiet_mode=True, skip_context_files=True, skip_memory=True, provider="anthropic",
                    api_key=ANT_KEY, base_url="https://api.anthropic.com", api_mode="anthropic_messages", model=mid)
        kw = build_api_kwargs(a, MSG, None)
    check(f"anthropic main agent, configured {mid}: wire model and speed", (a.provider, kw.get("model"), wire_speed(kw)),
          ("anthropic", want, speed))

# ── without an Anthropic credential: unaffected ──
setup(anthropic_key=False)
check("no anthropic key: catalog keeps Claude", "anthropic/claude-opus-5.5" in catalog_ids(), True)
check("no anthropic key: resolution stays on OpenRouter",
      resolve_runtime_provider(requested="openrouter", target_model="anthropic/claude-opus-5.5")["provider"],
      "openrouter")
rt = child_runtime("anthropic/claude-opus-5.5")
check("no anthropic key: delegate child stays on OpenRouter", (rt["provider"], rt["model"]),
      ("openrouter", "anthropic/claude-opus-5.5"))
agent = make_agent(provider="openrouter", model="anthropic/claude-opus-5.5")
check("no anthropic key: AIAgent stays on OpenRouter", agent.provider, "openrouter")

# ── option unset: upstream ──
setup(exclude=None)
check("option unset: catalog keeps Claude", "anthropic/claude-opus-5.5" in catalog_ids(), True)

if failures:
    print(f"{len(failures)} failed: {', '.join(failures)}")
    sys.exit(1)
print("all passed")
