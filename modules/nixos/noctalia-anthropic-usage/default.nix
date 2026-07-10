# Two mini bars in the noctalia bar showing how much of the weekly
# "Fable" allowance each logged-in Anthropic account has used.
#
# Two parts:
#   1. anthropic-usage-poll — a user timer (5 min) running poller.py:
#      reads every Anthropic OAuth login from omp's agent.db (READ-ONLY,
#      never refreshes tokens — a refresh rotates the refresh token and
#      would corrupt omp's copy), asks the OAuth usage endpoint for the
#      weekly Fable utilization and publishes
#      ~/.local/state/anthropic-usage.json. On fetch failure it falls
#      back, in order: Claude Code's own login (~/.claude/
#      .credentials.json — identity checked via the profile endpoint, an
#      expired grant refreshed and written back in place so the claude
#      CLI keeps working), omp's cached usage report, then the last
#      published value, marked stale.
#   2. an `anthropic-usage` noctalia plugin (plugin/) rendering one thin
#      gauge per account. merge.sh seeds it as an extra noctalia-shell
#      ExecStartPre AFTER the spaces bundle's noctalia-config-merge:
#      materialises the QML as per-file symlinks (same pattern as the
#      spaces plugins, so the stale-plugin purge leaves it alone),
#      enables it in plugins.json and APPENDS the widget to
#      bar.widgets.right — the user's own layout survives.
#
# Behavior tests: test-poller.py / test-merge.sh, wired as the
# `noctalia-anthropic-usage` flake check.
{ lib, pkgs, ... }:
let
  poller = pkgs.writeShellApplication {
    name = "anthropic-usage-poll";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./poller.py} "$@"
    '';
  };

  mergeConfig = pkgs.writeShellApplication {
    name = "noctalia-anthropic-usage-merge";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      export ANTHROPIC_USAGE_PLUGIN_SRC=${./plugin}
      ${builtins.readFile ./merge.sh}
    '';
  };
in
{
  systemd.user.services.anthropic-usage-poll = {
    description = "Publish per-account Anthropic Fable usage for the noctalia bar";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${poller}/bin/anthropic-usage-poll";
    };
  };

  systemd.user.timers.anthropic-usage-poll = {
    description = "Poll Anthropic Fable usage every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "10s";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };

  systemd.user.services.noctalia-shell = {
    # Runs after the spaces bundle's noctalia-config-merge (mkAfter), so
    # its managed settings.json/plugins.json are already seeded.
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${mergeConfig}/bin/noctalia-anthropic-usage-merge"
    ];
    restartTriggers = [ mergeConfig ];
  };
}
