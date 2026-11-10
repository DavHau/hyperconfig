"""Offline check of model_catalog.openrouter_all_models (hermes-openrouter-all-models.patch).

A fake live OpenRouter catalog and a fake curated manifest; no network. Asserts:
- option off: the picker list is upstream's (curated rows only, badges unchanged);
- option on: curated rows first (order and badges unchanged), then every other live model with
  tool support, sorted by id, "free" where free; non-tool and image-generation models stay out;
- the disk cache records the option, a cold process serves it, flipping the option refetches;
- the surfaces that read the list see the full one: model_ids() (/model name lookup),
  curated_models_for_provider, provider_model_ids / cached_provider_model_ids (the desktop and
  dashboard's /api/model/options and the TUI's model.options), list_picker_providers (the
  messaging /model picker), and build_model_options_payload itself.
Run with HERMES_HOME pointing at an empty directory.
"""

import json
import os
import sys
import time
from pathlib import Path

home = Path(os.environ["HERMES_HOME"])
os.environ.setdefault("OPENROUTER_API_KEY", "fake-openrouter")

import hermes_cli.models as m  # noqa: E402
import hermes_cli.model_catalog as mc  # noqa: E402

TOOLS = ["tools", "temperature"]
PAID = {"prompt": "0.000001", "completion": "0.000002"}
FREE = {"prompt": "0", "completion": "0"}
LIVE = [
    {"id": "zeta/curated-first", "supported_parameters": TOOLS, "pricing": PAID},
    {"id": "alpha/curated-free", "supported_parameters": TOOLS, "pricing": FREE},
    {"id": "reflection/beam-1.0-501b-a23b", "supported_parameters": TOOLS, "pricing": PAID},
    {"id": "aaa/extra:free", "supported_parameters": TOOLS, "pricing": FREE},
    {"id": "mmm/no-tools", "supported_parameters": ["temperature"], "pricing": PAID},
    {"id": "curated/no-tools", "supported_parameters": ["temperature"], "pricing": PAID},
    {"id": "img/painter", "supported_parameters": TOOLS, "pricing": PAID,
     "architecture": {"output_modalities": ["image"]}},
]
MANIFEST = [("zeta/curated-first", ""), ("alpha/curated-free", ""), ("curated/no-tools", ""),
            ("gone/not-live", "")]

fetches = []


def fake_index(url, timeout, opener):
    fetches.append(url)
    return list(LIVE), {i["id"]: i for i in LIVE}


m._fetch_live_catalog_index = fake_index
mc.get_curated_openrouter_models = lambda: list(MANIFEST)
m.get_preferred_silent_default_model = lambda provider="openrouter": ""

failures = []


def check(name, got, want):
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"\n  got:  {got!r}\n  want: {want!r}"))
    if not ok:
        failures.append(name)


def set_option(value):
    cfg = {"model": {"provider": "openrouter", "default": "zeta/curated-first"}}
    if value is not None:
        cfg["model_catalog"] = {"openrouter_all_models": value}
    import yaml
    (home / "config.yaml").write_text(yaml.safe_dump(cfg))
    # The config loader caches on the file signature; same-second rewrites keep the size apart
    # only by luck, so bump the mtime explicitly.
    t = time.time() + len(fetches) + 1
    os.utime(home / "config.yaml", (t, t))


def cold():
    m._openrouter_catalog_cache = None
    m._openrouter_all_catalog_cache = None


CURATED = [("zeta/curated-first", "recommended"), ("alpha/curated-free", "free")]
FULL = CURATED + [("aaa/extra:free", "free"), ("reflection/beam-1.0-501b-a23b", "")]

# Off (unset and explicit false): upstream's list.
set_option(None)
cold()
check("unset: curated only", m.fetch_openrouter_models(force_refresh=True), CURATED)
set_option(False)
cold()
check("false: curated only", m.fetch_openrouter_models(force_refresh=True), CURATED)
check("false: disk cache marked all_models=false",
      json.loads(m._openrouter_catalog_disk_path().read_text()).get("all_models"), False)

# Flip on: the fresh curated-only disk copy must not be served.
set_option(True)
cold()
n = len(fetches)
check("true: curated first, then every tool model sorted", m.fetch_openrouter_models(), FULL)
check("true: flipping the option refetched", len(fetches), n + 1)
check("true: disk cache marked all_models=true",
      json.loads(m._openrouter_catalog_disk_path().read_text()).get("all_models"), True)

# Cold process with the option on: served from disk, no fetch.
cold()
n = len(fetches)
check("true: cold process served from disk", m.fetch_openrouter_models(), FULL)
check("true: no fetch for the disk hit", len(fetches), n)

# cache_only (the GUI / messaging read path) accepts any copy on disk.
cold()
check("true: cache_only serves the disk copy", m.fetch_openrouter_models(cache_only=True), FULL)

# Consumers.
cold()
check("model_ids()", m.model_ids(), [mid for mid, _ in FULL])
check("_find_openrouter_slug finds a non-curated model by bare name",
      m._find_openrouter_slug("beam-1.0-501b-a23b"), "reflection/beam-1.0-501b-a23b")
check("curated_models_for_provider", m.curated_models_for_provider("openrouter"), FULL)
check("provider_model_ids", list(m.provider_model_ids("openrouter", force_refresh=True)),
      [mid for mid, _ in FULL])
check("cached_provider_model_ids", list(m.cached_provider_model_ids("openrouter", force_refresh=True)),
      [mid for mid, _ in FULL])

set_option(False)
fp_off = m._credential_fingerprint("openrouter")
set_option(True)
fp_on = m._credential_fingerprint("openrouter")
check("provider_models_cache fingerprint follows the option", fp_off != fp_on, True)

from hermes_cli.model_switch_providers import list_picker_providers  # noqa: E402
cold()
rows = list_picker_providers(current_provider="openrouter", current_model="zeta/curated-first",
                             max_models=50, non_blocking_catalogs=True)
row = next((r for r in rows if r.get("slug") == "openrouter"), None)
check("list_picker_providers (/model picker) row", (row or {}).get("models"), [mid for mid, _ in FULL])

from hermes_cli.inventory import build_model_options_payload, load_picker_context  # noqa: E402
cold()
payload = build_model_options_payload(load_picker_context(), refresh=False)
row = next((r for r in payload["providers"] if r.get("slug") == "openrouter"), None)
models = (row or {}).get("models") or []
check("model options payload (desktop/dashboard/TUI) lists the full set",
      [x for x in models if x in {mid for mid, _ in FULL}], [mid for mid, _ in FULL])

if failures:
    print(f"{len(failures)} failed: {', '.join(failures)}")
    sys.exit(1)
print("all passed")
