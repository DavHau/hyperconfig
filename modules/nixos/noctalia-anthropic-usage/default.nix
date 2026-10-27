# Two mini bars in the noctalia bar, one per Claude account pooled in our
# TeamClaude gateway, each overlaying the weekly all-model usage and the
# weekly Fable usage.
#
# Two parts:
#   1. anthropic-usage-poll — a user timer (5 min) running poller.py:
#      fetches the gateway's GET /teamclaude/status
#      (https://teamclaude.davhau.com, ../teamclaude-gateway on som) with
#      the shared teamclaude-api-key client key as x-api-key and publishes
#      both weekly utilizations per account to
#      ~/.local/state/anthropic-usage.json. The gateway knows an account's
#      quota from the rate-limit headers of the traffic it forwards and of
#      its own probes, so no omp database or per-account token is involved.
#      A failed fetch keeps the last published values, marked stale.
#   2. a `hyperconfig/anthropic-usage` noctalia plugin (plugin/, Luau)
#      rendering one thin gauge per account, placed in the bar's end
#      section just before the toggle buttons.
#
# Behavior tests: test-poller.py, wired as the `noctalia-anthropic-usage`
# flake check.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  poller = pkgs.writeShellApplication {
    name = "anthropic-usage-poll";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./poller.py} "$@"
    '';
  };
in
{
  # The client key: the shared clan var, readable by the user via group
  # teamclaude-api-key.
  imports = [ ../teamclaude-api-key.nix ];

  systemd.user.services.anthropic-usage-poll = {
    description = "Publish per-account Anthropic weekly usage for the noctalia bar";
    environment.TEAMCLAUDE_KEY_FILE = config.clan.core.vars.generators.teamclaude-api-key.files.key.path;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${poller}/bin/anthropic-usage-poll";
    };
  };

  systemd.user.timers.anthropic-usage-poll = {
    description = "Poll Anthropic weekly usage every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "10s";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };

  services.noctalia = {
    plugins.anthropic-usage = ./plugin;
    settings = {
      # Before the default-priority toggle buttons, after the base widgets.
      bar.default.end = lib.mkOrder 900 [ "anthropic-usage" ];
      widget.anthropic-usage.type = "hyperconfig/anthropic-usage:usage";
    };
  };
}
