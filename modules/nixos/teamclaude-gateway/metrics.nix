# Pushes TeamClaude usage to Mimir for the "TeamClaude usage" dashboard
# (../monitoring-teamclaude.nix on the monitoring server).
#
# TeamClaude books usage per client key in teamclaude.state.json: lifetime
# counters (clients.<name>.requests/inputTokens/outputTokens; they restart
# at 0 only if the file is wiped, which increase() absorbs) plus 15-minute
# slots that cover only the last ~24 h. The same file carries each
# account's last seen weekly quota (quota[].quota.unified7d, a share 0..1,
# and unified7dReset, epoch ms). A root timer turns both into a textfile
# for Alloy, like ../monitoring-zfs-pools.nix: the state dir stays 0700
# teamclaude, only the derived numbers leave it. Accounts are labelled by
# their TeamClaude name (the Claude login's email, or `fallback`), never
# by anything secret.
#
# History before this exporter ran exists only for the accounts
# (teamclaude.quota-series.json, ~7 days); it was imported once into Mimir
# by hand over OTLP (see ../monitoring-teamclaude.nix).
{ config, lib, pkgs, ... }:
let
  dir = "/run/teamclaude-metrics";
  stateFile = "/var/lib/teamclaude/teamclaude.state.json";
  jqProgram = pkgs.writeText "teamclaude-metrics.jq" ''
    def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; " ");
    def fam($name; $type; $label; $rows):
      "# TYPE \($name) \($type)",
      ($rows[] | "\($name){\($label)=\"\(.n | esc)\"} \(.v)");
    ((.clients // {}) | to_entries) as $c
    | [ (.quota // [])[] | select(.name != null and .quota.unified7d != null) ] as $q
    | fam("teamclaude_client_requests_total"; "counter"; "client";
        [ $c[] | { n: .key, v: (.value.requests // 0) } ]),
      fam("teamclaude_client_input_tokens_total"; "counter"; "client";
        [ $c[] | { n: .key, v: (.value.inputTokens // 0) } ]),
      fam("teamclaude_client_output_tokens_total"; "counter"; "client";
        [ $c[] | { n: .key, v: (.value.outputTokens // 0) } ]),
      fam("teamclaude_account_weekly_utilization"; "gauge"; "account";
        [ $q[] | { n: .name, v: .quota.unified7d } ]),
      fam("teamclaude_account_weekly_reset_timestamp_seconds"; "gauge"; "account";
        [ $q[] | select(.quota.unified7dReset != null) | { n: .name, v: (.quota.unified7dReset / 1000 | floor) } ])
  '';
in
{
  systemd.services.teamclaude-metrics = {
    description = "Write TeamClaude usage counters for Alloy";
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "teamclaude-metrics";
      RuntimeDirectoryPreserve = true;
    };
    # Renamed into place so Alloy never reads a half-written file; a missing
    # state file (fresh gateway) just leaves the old one.
    script = ''
      [ -e ${stateFile} ] || exit 0
      ${lib.getExe pkgs.jq} -r -f ${jqProgram} ${stateFile} > ${dir}/teamclaude.prom.tmp
      mv ${dir}/teamclaude.prom.tmp ${dir}/teamclaude.prom
    '';
  };

  systemd.timers.teamclaude-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  environment.etc."alloy/teamclaude.alloy".text = ''
    prometheus.exporter.unix "teamclaude" {
      set_collectors = [ "textfile" ]
      textfile {
        directory = "${dir}"
      }
    }

    prometheus.scrape "teamclaude" {
      targets = prometheus.exporter.unix.teamclaude.targets
      forward_to = [prometheus.relabel.teamclaude.receiver]
      scrape_interval = "60s"
    }

    prometheus.relabel "teamclaude" {
      forward_to = [prometheus.remote_write.mimir.receiver]

      rule {
        action = "keep"
        source_labels = ["__name__"]
        regex = "teamclaude_.*"
      }
    }
  '';
}
