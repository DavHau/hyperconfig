# hermes-claude-auth (github.com/kristianvast/hermes-claude-auth) for every
# hermes microVM on this host: a runtime patch of hermes-agent's anthropic
# adapter that makes OAuth (Claude Pro/Max subscription) requests pass
# Anthropic's Claude-Code billing validator. Vendored copy + provenance in
# ./hermes-claude-auth/.
#
# Why not upstream's install.sh: it copies a `.pth` + bootstrap module into
# the hermes venv's site-packages and the patch into $HERMES_HOME/patches.
# In a hermes microVM the hermes that runs (gateway unit, dashboard unit,
# the ssh'd CLI/TUI) is the sealed uv2nix venv of the hermes-agent flake
# package, read-only in /nix/store. The writable venv the guest also has
# (hermes-python-venv.service, /var/lib/hermes/.venv) is the AGENT's pip
# playground and never imports hermes, so a .pth there would be inert.
# Instead everything ships as one store directory and the hermes wrapper
# family gets PYTHONPATH pointed at it: site.py imports `sitecustomize`
# from sys.path and PYTHONPATH precedes the stdlib, so the loader in
# ./hermes-claude-auth/sitecustomize.py runs at interpreter start exactly
# where upstream's .pth would (see that file for the interpreter gate).
# The patch module sits in the same directory, so the bootstrap's
# `import anthropic_billing_bypass` resolves without $HERMES_HOME/patches;
# that directory is intentionally left alone (if someone runs upstream's
# install.sh inside a guest, its copy takes precedence — upstream semantics).
#
# Pure Nix: no oneshot, nothing to re-run after hermes-python-venv.service
# recreates the writable venv, survives restarts and rebuilds, updates with
# the vendored file. Injection points in the guest (all three use the same
# wrapper, and PYTHONPATH is inherited by the TUI's python worker):
#   - hermes-agent.service      (gateway)
#   - hermes-dashboard.service  (web dashboard backend)
#   - /run/current-system/sw/bin/hermes  (what the host `hermes` shim execs
#     over vsock ssh), shadowed by a hiPrio wrapper.
#
# The Claude Code CLI is added to the guest PATH: the patch signs headers
# with `claude --version`, and the OAuth login (`claude` -> /login) is done
# inside the guest so ~/.claude/.credentials.json lands in the exchange dir
# (guest HOME). Hermes itself already knows Claude Code credentials: once
# anthropic is the configured provider, agent/credential_pool.py seeds a
# `claude_code` entry into $HERMES_HOME/auth.json from that file. The
# patch adds what hermes lacks on the wire (billing-header signature,
# Claude Code identity/system-prompt layout, Stainless headers, tool-name
# namespacing, thinking-replay and 429 handling).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-microvm;

  guestModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      site = pkgs.runCommand "hermes-claude-auth-site" { } ''
        mkdir -p $out
        cp ${./hermes-claude-auth/sitecustomize.py} $out/sitecustomize.py
        cp ${./hermes-claude-auth/_hermes_claude_auth_bootstrap.py} $out/_hermes_claude_auth_bootstrap.py
        cp ${./hermes-claude-auth/anthropic_billing_bypass.py} $out/anthropic_billing_bypass.py
      '';
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
in
{
  config = lib.mkIf cfg.enable {
    services.hermes-microvm.extraPackages = [ pkgs.claude-code ];
    # VM name = hlib.vmName in the spaces hermes module ("hermes-<user>").
    microvm.vms = lib.mapAttrs' (
      user: _: lib.nameValuePair "hermes-${user}" { config = guestModule; }
    ) cfg.enabledUsers;
  };
}
