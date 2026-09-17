# hermes-claude-auth (github.com/kristianvast/hermes-claude-auth) for every
# hermes agent on this host, microVM or native: a runtime patch of
# hermes-agent's anthropic adapter that makes OAuth (Claude Pro/Max
# subscription) requests pass Anthropic's Claude-Code billing validator.
# Vendored copy + provenance in ./hermes-claude-auth/.
#
# Why not upstream's install.sh: it copies a `.pth` + bootstrap module into
# the hermes venv's site-packages and the patch into $HERMES_HOME/patches.
# The hermes that runs (gateway unit, dashboard unit, the CLI/TUI) is the
# sealed uv2nix venv of the hermes-agent flake package, read-only in
# /nix/store. The writable venv beside it (hermes-python-venv service,
# <state>/.venv) is the AGENT's pip playground and never imports hermes, so
# a .pth there would be inert. Instead everything ships as one store
# directory and the hermes wrapper family gets PYTHONPATH pointed at it:
# site.py imports `sitecustomize` from sys.path and PYTHONPATH precedes the
# stdlib, so the loader in ./hermes-claude-auth/sitecustomize.py runs at
# interpreter start exactly where upstream's .pth would (see that file for
# the interpreter gate). The patch module sits in the same directory, so
# the bootstrap's `import anthropic_billing_bypass` resolves without
# $HERMES_HOME/patches; that directory is intentionally left alone (if
# someone runs upstream's install.sh, its copy takes precedence — upstream
# semantics).
#
# Pure Nix: no oneshot, nothing to re-run after the venv service recreates
# the writable venv, survives restarts and rebuilds, updates with the
# vendored file. PYTHONPATH is inherited by the TUI's python worker.
#
# Injection points, VM user (guest config, microvm.vms."hermes-<user>"):
#   - hermes-agent.service      (gateway)
#   - hermes-dashboard.service  (web dashboard backend)
#   - /run/current-system/sw/bin/hermes  (what the host `hermes` shim execs
#     over vsock ssh), shadowed by a hiPrio wrapper.
# Native user (spaces hermes/native.nix, host units as the owner):
#   - hermes-agent-<user>.service, hermes-dashboard-<user>.service: unit
#     environment. (Not the .env file: agent-config.nix strips PYTHONPATH
#     from it before every start, on purpose.)
#   - the host `hermes` shim (spaces hermes/cli.nix) execs the sealed
#     package directly. It is not addressable from here (recursion through
#     environment.systemPackages), and users.users.<u>.packages recurses
#     too (services.hermes-microvm.users defaults from users.users). So a
#     wrapper that exports PYTHONPATH and execs the shim by its runtime
#     path is put on PATH through environment.profiles: a plain entry
#     precedes /run/current-system/sw (mkAfter in programs/environment.nix).
#     Only bin/hermes lives there, and for a VM user it is inert (ssh does
#     not forward PYTHONPATH).
#
# The Claude Code CLI is on the agent's PATH (extraPackages feeds both the
# guest and the native runtime): the patch signs headers with
# `claude --version`, and Anthropic rejects versions below a moving
# minimum ("Claude Code 2.1.238 does not support this model; version
# 2.1.251 or newer is required"). Hence the llm-agents.nix package, the
# one packages.nix ships system-wide, not nixpkgs' lagging one: the
# agent's PATH puts extraPackages ahead of /run/current-system/sw, so a
# stale pin here beats a fresh system profile. Bump llm-agents when it
# hits again. The OAuth login (`claude` -> /login) must write
# ~/.claude/.credentials.json into the AGENT's HOME, the exchange dir:
# inside the guest that is just $HOME; a native owner runs
# `HOME=~/hermes claude` on the host (claude-code is in systemPackages
# for that). Hermes itself already knows Claude Code credentials:
# once anthropic is the configured provider, agent/credential_pool.py
# seeds a `claude_code` entry into $HERMES_HOME/auth.json from that file.
# The patch adds what hermes lacks on the wire (billing-header signature,
# Claude Code identity/system-prompt layout, Stainless headers, tool-name
# namespacing, thinking-replay and 429 handling).
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  claude-code = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
  cfg = config.services.hermes-microvm;

  site = pkgs.runCommand "hermes-claude-auth-site" { } ''
    mkdir -p $out
    cp ${./hermes-claude-auth/sitecustomize.py} $out/sitecustomize.py
    cp ${./hermes-claude-auth/_hermes_claude_auth_bootstrap.py} $out/_hermes_claude_auth_bootstrap.py
    cp ${./hermes-claude-auth/anthropic_billing_bypass.py} $out/anthropic_billing_bypass.py
  '';

  guestModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      hermes = config.services.hermes-agent.package;
      # Shadows the plain package's bin/hermes in systemPackages
      # (guest.nix's addToSystemPackages); hermes-agent's wrapper only
      # touches PYTHONPATH when extraPythonPackages is set, so ours passes
      # through to the console script.
      hookedCli = lib.hiPrio (
        pkgs.writeShellScriptBin "hermes" ''
          export PYTHONPATH=${site}''${PYTHONPATH:+:$PYTHONPATH}
          exec ${hermes}/bin/hermes "$@"
        ''
      );
    in
    {
      systemd.services.hermes-agent.environment.PYTHONPATH = "${site}";
      systemd.services.hermes-dashboard.environment.PYTHONPATH = "${site}";
      environment.systemPackages = [ hookedCli ];
      # Discoverable path for humans/`install.sh --check`-style probes.
      environment.etc."hermes-claude-auth".source = site;
    };

  # Native: same PYTHONPATH ahead of the spaces shim. The shim keeps the
  # caller's PYTHONPATH (it only exports the runtime's own keys), and the
  # sealed package's wrapper passes it through as in the guest.
  hookedShim = pkgs.writeShellScriptBin "hermes" ''
    export PYTHONPATH=${site}''${PYTHONPATH:+:$PYTHONPATH}
    exec /run/current-system/sw/bin/hermes "$@"
  '';
  # Static top-level keys only (see native.nix): a config-dependent list
  # at the config root would recurse through cfg.nativeUsers.
  forEachNative = f: lib.mkMerge (lib.mapAttrsToList f cfg.nativeUsers);
  anyNative = cfg.nativeUsers != { };
in
{
  config = lib.mkIf cfg.enable {
    services.hermes-microvm.extraPackages = [ claude-code ];
    # VM name = hlib.vmName in the spaces hermes module ("hermes-<user>").
    # VM users only: a native user runs host units, and a microvm.vms
    # entry for it would declare a guest nobody builds.
    microvm.vms = lib.mapAttrs' (
      user: _: lib.nameValuePair "hermes-${user}" { config = guestModule; }
    ) cfg.vmUsers;

    systemd.services = forEachNative (user: _: {
      "hermes-agent-${user}".environment.PYTHONPATH = "${site}";
      "hermes-dashboard-${user}".environment.PYTHONPATH = "${site}";
    });
    environment.profiles = lib.mkIf anyNative [ "${hookedShim}" ];
    # For the owner's OAuth login on the host (HOME=~/hermes claude).
    environment.systemPackages = lib.mkIf anyNative [ claude-code ];
    environment.etc."hermes-claude-auth" = lib.mkIf anyNative { source = site; };
  };
}
