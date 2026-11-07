"""Runs one command through hermes' terminal tool, via its tool registry like the agent loop,
for the hardening check (default.nix). Run with hermes' own interpreter in the gateway's
environment. Prints the tool's JSON result on a line of its own after "RESULT ".
"""
import sys

import model_tools  # noqa: F401,E402  (registers the tools)
from tools.registry import registry  # noqa: E402

out = registry.dispatch("terminal", {"command": sys.argv[1], "timeout": 120}, task_id="hardening")
print("RESULT " + out, flush=True)
