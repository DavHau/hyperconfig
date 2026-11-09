"""Offline check: every main model gets a working image path.

Runs in hermes' own venv against $HERMES_HOME/config.yaml (written by
./default.nix): p0's Qwen declared vision-capable, auxiliary.vision on p0.
No model is called: credentials are fake, the models.dev catalog is a
two-entry stub on disk, clients are only resolved.

  - Claude (anthropic) and p0's Qwen keep native pixels: user uploads,
    vision_analyze's and browser_vision's tool-result images;
  - a text-only main model (GLM on OpenRouter) is described by p0's Qwen;
  - vision_analyze is offered to every one of them, also right after
    another model's turn in the same process (the check_fn and tool-list
    caches are per main model);
  - camofox' browser_vision attaches the screenshot for Claude, asks the
    describer for GLM.
"""

import struct
import sys
import zlib

from agent.auxiliary_client import _RUNTIME_MAIN_CONTEXT, resolve_vision_provider_client, set_runtime_main
from agent.image_routing import decide_image_input_mode
from hermes_cli.config import load_config

import model_tools
from tools.vision_tools import _native_tool_result_images, check_vision_requirements

failures = []


def expect(name, got, want):
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (want {want!r})"))
    if not ok:
        failures.append(name)


OPUS = ("anthropic", "claude-opus-5-5", "")
QWEN = ("custom", "qwen", "custom:p0")
QWEN_SERVED = ("custom", "Qwen3.8-27B-FP8", "custom:p0")
GLM = ("openrouter", "z-ai/glm-5.3", "")


class main:
    """The main model of one turn, as hermes' turn_context binds it."""

    def __init__(self, runtime):
        self.provider, self.model, self.requested = runtime

    def __enter__(self):
        self.token = set_runtime_main(self.provider, self.model, requested_provider=self.requested)
        return self

    def __exit__(self, *exc):
        _RUNTIME_MAIN_CONTEXT.reset(self.token)


def vision_tools():
    names = (t["function"]["name"] for t in model_tools.get_tool_definitions(enabled_toolsets=["vision"], quiet_mode=True))
    return sorted(n for n in names if n == "vision_analyze")


cfg = load_config()

# 1. p0's Qwen is vision-capable (providers.p0.models.<m>.supports_vision).
for label, rt in (("opus", OPUS), ("qwen", QWEN), ("qwen served name", QWEN_SERVED), ("glm", GLM)):
    with main(rt):
        want = "text" if rt is GLM else "native"
        expect(f"{label}: upload routing", decide_image_input_mode(rt[0], rt[1], cfg, requested_provider=rt[2]), want)
        expect(f"{label}: tool-result images native", _native_tool_result_images(rt[0], rt[1], cfg), rt is not GLM)

# 2. The describer for a text-only main model is p0's Qwen.
with main(GLM):
    provider, client, model = resolve_vision_provider_client()
    expect("glm: vision backend", (provider, client is not None, model), ("p0", True, "qwen"))
    expect("glm: vision backend endpoint", str(getattr(client, "base_url", "")).rstrip("/"), "https://inference.p0.contact/v1")

# 3. vision_analyze for every model, in any order within one process.
for order in ((GLM, OPUS, QWEN), (OPUS, GLM, QWEN)):
    for rt in order:
        with main(rt):
            expect(f"{rt[1]} after {[o[1] for o in order[:order.index(rt)]]}: check", check_vision_requirements(), True)
            expect(f"{rt[1]} after {[o[1] for o in order[:order.index(rt)]]}: tools", vision_tools(), ["vision_analyze"])

# 4. camofox' browser_vision: native for Claude, the describer for GLM.
import tools.browser_camofox as camofox  # noqa: E402
import agent.auxiliary_client as aux  # noqa: E402


def png():
    raw = b"\x00\xff\x00\x00"
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Raw:
    content = png()


described = []


class Reply:
    class choices_0:
        class message:
            content = "a green pixel"
    choices = [choices_0]


camofox._require_tab = lambda task_id, action=None: ({"tab_id": "t", "user_id": "u"}, None)
camofox._get_raw = lambda *a, **k: Raw()
aux.call_llm = lambda **kw: described.append(kw.get("task")) or Reply()

with main(OPUS):
    result = camofox.camofox_vision("what colour?")
    expect("opus: camofox screenshot native", isinstance(result, dict) and result.get("_multimodal"), True)
expect("opus: camofox asked no describer", described, [])
with main(GLM):
    result = camofox.camofox_vision("what colour?")
    expect("glm: camofox described", ("a green pixel" in result, described), (True, ["vision"]))

# 5. Without auxiliary.vision GLM has no vision backend (hermes' auto route
# finds none) and loses vision_analyze; that verdict must not leak into the
# next Claude session's tool list, nor Claude's into GLM's.
import os  # noqa: E402
import time  # noqa: E402

import yaml  # noqa: E402

config_path = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
with open(config_path) as f:
    raw = yaml.safe_load(f)
raw.pop("auxiliary")
with open(config_path, "w") as f:
    yaml.safe_dump(raw, f)
st = os.stat(config_path)
os.utime(config_path, ns=(st.st_atime_ns, st.st_mtime_ns + 10**9))  # a new config signature
time.sleep(0.1)
# Fresh caches: the verdicts of 3. would otherwise stand for their TTL.
from tools.registry import invalidate_check_fn_cache  # noqa: E402

invalidate_check_fn_cache()
for rt, want in ((GLM, []), (OPUS, ["vision_analyze"]), (GLM, []), (QWEN, ["vision_analyze"])):
    with main(rt):
        expect(f"no aux.vision: {rt[1]} tools", vision_tools(), want)

if failures:
    print(f"{len(failures)} failure(s): {failures}")
    sys.exit(1)
print("all vision scenarios hold")
