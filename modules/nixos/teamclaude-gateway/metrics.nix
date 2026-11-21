# Pushes TeamClaude usage to Mimir for the "TeamClaude usage" dashboard
# (../monitoring-teamclaude on the monitoring server).
#
# TeamClaude books usage per client key in teamclaude.state.json: lifetime
# counters (clients.<name>.requests/inputTokens/outputTokens; they restart
# at 0 only if the file is wiped, which increase() absorbs) plus 15-minute
# slots that cover only the last ~24 h. The same file carries each
# account's last seen weekly quota (quota[].quota.unified7d, a share 0..1,
# and unified7dReset, epoch ms). A timer (as the teamclaude user) turns both into a textfile
# for Alloy, like ../monitoring-zfs-pools.nix: the state dir stays 0700
# teamclaude, only the derived numbers leave it. Accounts are labelled by
# their TeamClaude name (the Claude login's email, or `fallback`), never
# by anything secret.
#
# Each account's cap (maxUsage) and type/tier come from the live config
# (teamclaude.json, which also holds the OAuth tokens: only those three
# fields leave it).
# OAuth recovery alerts use the running gateway's authenticated loopback
# status, not the quota file: they export recorded refresh-token deadlines
# and confirmed auth rejections for enabled Anthropic subscription OAuth.
#
# Per client AND account, and with cache reads/writes and the model's price
# (which the lifetime counters above lack: their input is the uncached part
# only, and they say nothing about which account served), come from
# TeamClaude's own usage history (proxy.usageHistory, ./default.nix):
# ./usage-metrics.mjs turns its hourly rollup into
# teamclaude_client_cost_usd_total{client,account} (API list price) and
# teamclaude_client_tokens_total{client,account,kind}, which the usage pages
# (../monitoring-teamclaude) split each account's measured quota by.
#
# The unit runs as the teamclaude user, so the state stays 0700 teamclaude
# and the SQLite file is opened only by its owner (read-only).
#
# History before this exporter ran exists only for the accounts
# (teamclaude.quota-series.json, ~7 days); it was imported once into Mimir
# by hand over OTLP (see ../monitoring-teamclaude).
{ config, lib, pkgs, ... }:
let
  dir = "/run/teamclaude-metrics";
  stateFile = "/var/lib/teamclaude/teamclaude.state.json";
  configFile = "/var/lib/teamclaude/teamclaude.json";
  usageDb = "/var/lib/teamclaude/teamclaude.usage.db";
  # usage-metrics.mjs's running totals of closed hours.
  usageState = "/var/lib/teamclaude-metrics/usage-totals.json";
  configJq = pkgs.writeText "teamclaude-metrics-config.jq" ''
    def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; " ");
    [ (.accounts // [])[] | select(.name != null) ] as $a
    | "# TYPE teamclaude_account_max_usage gauge",
      ($a[] | select(.maxUsage != null) | "teamclaude_account_max_usage{account=\"\(.name | esc)\"} \(.maxUsage)"),
      "# TYPE teamclaude_account_info gauge",
      ($a[] | "teamclaude_account_info{account=\"\(.name | esc)\",type=\"\(.type // "" | esc)\",tier=\"\(.rateLimitTier // "" | esc)\"} 1")
  '';
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
    description = "Write TeamClaude usage and OAuth status for Alloy";
    serviceConfig = {
      Type = "oneshot";
      User = "teamclaude";
      Group = "teamclaude";
      RuntimeDirectory = "teamclaude-metrics";
      RuntimeDirectoryPreserve = true;
      # Alloy (a DynamicUser) reads the textfiles.
      RuntimeDirectoryMode = "0755";
      StateDirectory = "teamclaude-metrics";
      UMask = "0022";
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
    };
    # Renamed into place so Alloy never reads a half-written file; a missing
    # state file (fresh gateway) just leaves the old one. The usage history
    # goes to a file of its own, so a failure there (a schema TeamClaude
    # changed) leaves the counters above flowing; the unit still fails.
    script = ''
      # Keep the last atomic snapshot if status fails. The alert queries
      # check its embedded timestamp, not the Alloy re-scrape timestamp.
      if ${pkgs.nodejs}/bin/node ${./oauth-status.mjs} ${configFile} > ${dir}/teamclaude-oauth.prom.tmp; then
        mv ${dir}/teamclaude-oauth.prom.tmp ${dir}/teamclaude-oauth.prom
      else
        rm -f ${dir}/teamclaude-oauth.prom.tmp
      fi
      [ -e ${stateFile} ] || exit 0
      { ${lib.getExe pkgs.jq} -r -f ${jqProgram} ${stateFile}
        ${lib.getExe pkgs.jq} -r -f ${configJq} ${configFile}
      } > ${dir}/teamclaude.prom.tmp
      mv ${dir}/teamclaude.prom.tmp ${dir}/teamclaude.prom
      ${pkgs.nodejs}/bin/node --no-warnings ${./usage-metrics.mjs} \
        ${config.services.teamclaude.package}/share/teamclaude/src \
        ${usageDb} ${usageState} > ${dir}/teamclaude-usage.prom.tmp
      mv ${dir}/teamclaude-usage.prom.tmp ${dir}/teamclaude-usage.prom
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
