# Two mini bars in the noctalia bar, one per logged-in Anthropic account,
# each overlaying the weekly all-model usage and the weekly Fable usage.
#
# Two parts:
#   1. anthropic-usage-poll — a user timer (5 min) running poller.py:
#      collects the Anthropic OAuth logins from every omp agent.db
#      (~/.omp/agent/agent.db + ~/.omp/profiles/*/agent/agent.db,
#      READ-ONLY, never refreshes tokens — a refresh rotates the refresh
#      token and would corrupt omp's copy), takes the latest-expiring
#      token per account, asks the OAuth usage endpoint for both weekly
#      utilizations and publishes ~/.local/state/anthropic-usage.json.
#      omp moves its login store between releases (≥18.6 keeps it in the
#      shared agent.db), so no single profile is trusted. Accounts with
#      no unexpired token are not queried; they, like failed fetches,
#      keep their last published values, marked stale.
#   2. a `hyperconfig/anthropic-usage` noctalia plugin (plugin/, Luau)
#      rendering one thin gauge per account, placed in the bar's end
#      section just before the toggle buttons.
#
# Behavior tests: test-poller.py, wired as the `noctalia-anthropic-usage`
# flake check.
{ lib, pkgs, ... }:
let
  poller = pkgs.writeShellApplication {
    name = "anthropic-usage-poll";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./poller.py} "$@"
    '';
  };
in
{
  systemd.user.services.anthropic-usage-poll = {
    description = "Publish per-account Anthropic weekly usage for the noctalia bar";
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
