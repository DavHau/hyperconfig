# hermes-claude-auth managed — NixOS loader (replaces upstream's .pth shim)
#
# Upstream drops `hermes_claude_auth.pth` into the hermes venv's
# site-packages, and site.py exec's it at interpreter start. The hermes
# that runs in a hermes microVM is a sealed uv2nix venv in /nix/store: its
# site-packages is read-only and it has no site dir we could add a .pth to
# (user site is disabled inside a venv, and the venv does not see the base
# interpreter's site-packages, so nixpkgs' NIX_PYTHONPATH sitecustomize is
# not even on its path). What CAN be reached is PYTHONPATH: site.py imports
# `sitecustomize` from sys.path, and PYTHONPATH entries precede the stdlib.
# hermes-claude-auth.nix therefore points PYTHONPATH at the directory
# holding this file, the upstream bootstrap and the patch module.
#
# Scope: PYTHONPATH is inherited by every child of hermes (TUI worker,
# terminal-tool shells...). Only the interpreter hermes itself runs on
# (HERMES_PYTHON, exported by the hermes wrapper) gets the hook, so the
# agent's own `python` in the writable venv stays untouched. Any
# interpreter that does carry a nixpkgs sitecustomize (writable venv,
# bare nixpkgs python) has it chain-loaded so NIX_PYTHONPATH handling is
# preserved.
import os
import runpy
import sys


def _is_hermes_interpreter() -> bool:
    hermes_python = os.environ.get("HERMES_PYTHON")
    if not hermes_python:
        return True
    try:
        return os.path.realpath(hermes_python) == os.path.realpath(sys.executable)
    except OSError:
        return False


def _chain_nixpkgs_sitecustomize() -> None:
    candidate = os.path.join(
        sys.base_prefix,
        "lib",
        "python%d.%d" % sys.version_info[:2],
        "site-packages",
        "sitecustomize.py",
    )
    if os.path.isfile(candidate) and os.path.realpath(candidate) != os.path.realpath(__file__):
        runpy.run_path(candidate, run_name="sitecustomize")


if _is_hermes_interpreter():
    import _hermes_claude_auth_bootstrap  # noqa: F401  (installs the import hooks)

_chain_nixpkgs_sitecustomize()
