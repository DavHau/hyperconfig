# hermes-claude-auth (github.com/kristianvast/hermes-claude-auth) for every
# hermes agent on this host (`services.hyperhermes.claudeAuth.enable`, for
# all of services.hyperhermes.agents): a runtime patch
# of hermes-agent's anthropic adapter that makes OAuth (Claude Pro/Max
# subscription) requests pass Anthropic's Claude-Code billing validator.
# Vendored copy + provenance beside this file.
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
# stdlib, so the loader in ./sitecustomize.py runs at
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
# Injection points (core, host units as the owner):
#   - hermes-agent-<user>.service, hermes-dashboard-<user>.service: unit
#     environment. (Not the .env file: core strips PYTHONPATH from it
#     before every start, on purpose.)
#   - the host `hermes` shim (core) execs the sealed package directly. It
#     is not addressable from here (recursion through
#     environment.systemPackages), and users.users.<u>.packages would tie
#     the account to the agent list. So a wrapper that exports PYTHONPATH
#     and execs the shim by its runtime path is put on PATH through
#     environment.profiles: a plain entry precedes /run/current-system/sw
#     (mkAfter in programs/environment.nix). Only bin/hermes lives there.
#
# Hermes runs `claude --version` (the patch for the billing-header
# signature and user-agent, hermes' own adapter for the user-agent), and
# Anthropic rejects versions below a moving minimum ("Claude Code 2.1.238
# does not support this model; version 2.1.251 or newer is required").
# Only the leading X.Y.Z token of that output is read, so the agents'
# PATH (services.hyperhermes extraPackages, ahead of
# /run/current-system/sw) gets a `claude` stub that prints
# claudeCodeVersion instead of the real CLI. Its default is the
# @anthropic-ai/claude-code npm release in ./claude-code-version; run
# ./update-claude-code-version.sh when the minimum hits again. Any other
# invocation fails, so hermes' `claude setup-token` wizard falls through
# to pasting a token and the claude-code skill reports the CLI missing.
#
# Login needs no CLI: `hermes auth add anthropic --type oauth` (or the
# dashboard) runs hermes' own PKCE flow with Claude Code's OAuth client
# and keeps the tokens in hermes' credential pool. The patch rewrites
# every OAuth request, whatever the credential's source. It adds what
# hermes lacks on the wire (billing-header signature, Claude Code
# identity/system-prompt layout, Stainless headers, tool-name
# namespacing, thinking-replay and 429 handling).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.claudeAuth;
  agents = config.services.hyperhermes.agents;

  site = pkgs.runCommand "hermes-claude-auth-site" { } ''
    mkdir -p $out
    cp ${./sitecustomize.py} $out/sitecustomize.py
    cp ${./_hermes_claude_auth_bootstrap.py} $out/_hermes_claude_auth_bootstrap.py
    cp ${./anthropic_billing_bypass.py} $out/anthropic_billing_bypass.py
  '';

  # The same PYTHONPATH ahead of core's shim. The shim keeps the caller's
  # PYTHONPATH (it only exports the runtime's own keys), and the sealed
  # package's wrapper passes it through.
  hookedShim = pkgs.writeShellScriptBin "hermes" ''
    export PYTHONPATH=${site}''${PYTHONPATH:+:$PYTHONPATH}
    exec /run/current-system/sw/bin/hermes "$@"
  '';
  # See the header: the version is all hermes reads from `claude`.
  claudeStub = pkgs.writeShellScriptBin "claude" ''
    if [ "$*" = --version ]; then
      echo "${cfg.claudeCodeVersion} (Claude Code)"
      exit 0
    fi
    echo "claude: version stub of hyperhermes' claude-auth, not the Claude Code CLI; log in with: hermes auth add anthropic --type oauth" >&2
    exit 1
  '';
  # Static top-level keys only (see core's agents.nix): a config-dependent
  # list at the config root would recurse through the agent list.
  forEachAgent = f: lib.mkMerge (lib.mapAttrsToList f agents);
in
{
  options.services.hyperhermes.claudeAuth = {
    enable = lib.mkEnableOption "the hermes-claude-auth patch (Claude Pro/Max OAuth through Anthropic's Claude Code billing validator) for every agent";
    claudeCodeVersion = lib.mkOption {
      type = lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+";
      default = lib.fileContents ./claude-code-version;
      defaultText = lib.literalMD "the version in `./claude-code-version` (latest @anthropic-ai/claude-code on npm when last updated)";
      example = "2.1.311";
      description = "The Claude Code version the agents' `claude --version` stub reports; the patch signs the billing header and user-agent with it.";
    };
  };

  config = lib.mkIf (cfg.enable && agents != { }) {
    services.hyperhermes.extraPackages = [ claudeStub ];
    systemd.services = forEachAgent (
      user: _: {
        "hermes-agent-${user}".environment.PYTHONPATH = "${site}";
        "hermes-dashboard-${user}".environment.PYTHONPATH = "${site}";
      }
    );
    environment.profiles = [ "${hookedShim}" ];
    environment.etc."hermes-claude-auth".source = site;
  };
}
