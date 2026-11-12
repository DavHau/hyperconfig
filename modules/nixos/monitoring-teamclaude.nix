# "TeamClaude usage" dashboard on the monitoring server's Grafana
# (stats.davhau.com/d/teamclaude-usage), fed by som's exporter
# (./teamclaude-gateway/metrics.nix): per client key output tokens and
# requests per day over the last two weeks, a this-week vs last-week table
# (rolling 7 days, from the lifetime counters via increase(), which absorbs
# a counter reset), and each account's weekly quota with its resets marked.
#
# Out-of-order window: TeamClaude keeps ~7 days of per-account quota
# history (teamclaude.quota-series.json); Mimir only accepts samples older
# than its head with an out-of-order window, so it is 8 days here. The
# history was imported once, by hand, over OTLP:
#   on som:  jq over the series file -> OTLP JSON gauges (labels account,
#            job="integrations/unix", instance="som", like Alloy's)
#   on edi:  curl -H 'Content-Type: application/json' --data-binary @-
#            http://127.0.0.1:3001/mimir/otlp/v1/metrics
{ config, lib, pkgs, ... }:
let
  ds = {
    type = "prometheus";
    uid =
      (lib.findFirst (d: d.type == "prometheus")
        (throw "monitoring-teamclaude: no prometheus datasource provisioned")
        config.services.grafana.provision.datasources.settings.datasources
      ).uid;
  };

  target = refId: expr: extra: { inherit refId expr; datasource = ds; } // extra;

  # Stacked daily bars per client.
  daily = id: title: metric: unit: y: {
    inherit id title;
    type = "timeseries";
    datasource = ds;
    gridPos = { h = 9; w = 12; x = if y == 0 then 0 else 12; y = 0; };
    interval = "1d";
    targets = [
      (target "A" "sum by (client) (increase(${metric}[$__interval]))" {
        legendFormat = "{{client}}";
      })
    ];
    fieldConfig = {
      defaults = {
        inherit unit;
        custom = {
          drawStyle = "bars";
          fillOpacity = 80;
          lineWidth = 0;
          stacking.mode = "normal";
        };
      };
      overrides = [ ];
    };
    options = {
      legend = { displayMode = "table"; placement = "right"; calcs = [ "sum" ]; };
      tooltip = { mode = "multi"; sort = "desc"; };
    };
  };

  week = refId: metric: offset:
    target refId "sum by (client) (increase(${metric}[7d]${offset}))" {
      instant = true;
      format = "table";
    };

  dashboard = {
    uid = "teamclaude-usage";
    title = "TeamClaude usage";
    tags = [ "teamclaude" ];
    timezone = "browser";
    schemaVersion = 39;
    refresh = "15m";
    time = { from = "now-14d"; to = "now"; };
    annotations.list = [
      {
        name = "Weekly resets";
        enable = true;
        iconColor = "orange";
        datasource = ds;
        # The reset timestamp moves forward once a request after the reset
        # sees the new window: one marker per account and reset.
        expr = "changes(teamclaude_account_weekly_reset_timestamp_seconds[30m]) > 0";
        step = "30m";
        titleFormat = "{{account}}: weekly quota reset";
        useValueForTime = false;
      }
    ];
    panels = [
      (daily 1 "Output tokens per day" "teamclaude_client_output_tokens_total" "short" 0)
      (daily 2 "Requests per day" "teamclaude_client_requests_total" "short" 1)
      {
        id = 3;
        title = "This week vs last week (rolling 7 days)";
        type = "table";
        datasource = ds;
        gridPos = { h = 9; w = 12; x = 0; y = 9; };
        targets = [
          (week "A" "teamclaude_client_output_tokens_total" "")
          (week "B" "teamclaude_client_output_tokens_total" " offset 7d")
          (week "C" "teamclaude_client_requests_total" "")
          (week "D" "teamclaude_client_requests_total" " offset 7d")
        ];
        transformations = [
          { id = "merge"; options = { }; }
          {
            id = "organize";
            options = {
              excludeByName.Time = true;
              renameByName = {
                client = "Client";
                "Value #A" = "Output tokens, this week";
                "Value #B" = "Output tokens, last week";
                "Value #C" = "Requests, this week";
                "Value #D" = "Requests, last week";
              };
            };
          }
        ];
        fieldConfig = {
          defaults = { unit = "short"; decimals = 0; };
          overrides = [ ];
        };
        options.sortBy = [ { displayName = "Output tokens, this week"; desc = true; } ];
      }
      {
        id = 4;
        title = "Account weekly quota used";
        type = "timeseries";
        datasource = ds;
        gridPos = { h = 9; w = 12; x = 12; y = 9; };
        targets = [
          (target "A" "max by (account) (teamclaude_account_weekly_utilization)" {
            legendFormat = "{{account}}";
          })
        ];
        fieldConfig = {
          defaults = {
            unit = "percentunit";
            min = 0;
            max = 1;
            custom = { lineWidth = 2; fillOpacity = 0; };
          };
          overrides = [ ];
        };
        options = {
          legend = { displayMode = "table"; placement = "bottom"; calcs = [ "lastNotNull" ]; };
          tooltip = { mode = "multi"; sort = "desc"; };
        };
      }
      {
        id = 5;
        title = "Next weekly reset";
        type = "table";
        datasource = ds;
        gridPos = { h = 6; w = 24; x = 0; y = 18; };
        targets = [
          (target "A" "max by (account) (teamclaude_account_weekly_reset_timestamp_seconds) * 1000" {
            instant = true;
            format = "table";
          })
          (target "B" "max by (account) (teamclaude_account_weekly_utilization)" {
            instant = true;
            format = "table";
          })
        ];
        transformations = [
          { id = "merge"; options = { }; }
          {
            id = "organize";
            options = {
              excludeByName.Time = true;
              renameByName = {
                account = "Account";
                "Value #A" = "Resets";
                "Value #B" = "Used";
              };
            };
          }
        ];
        fieldConfig = {
          defaults = { };
          overrides = [
            {
              matcher = { id = "byName"; options = "Resets"; };
              properties = [ { id = "unit"; value = "dateTimeFromNow"; } ];
            }
            {
              matcher = { id = "byName"; options = "Used"; };
              properties = [ { id = "unit"; value = "percentunit"; } ];
            }
          ];
        };
      }
    ];
  };
in
{
  services.mimir.configuration.limits.out_of_order_time_window = "8d";

  services.grafana.provision.dashboards.settings.providers = [
    {
      name = "teamclaude";
      options.path = pkgs.writeTextDir "teamclaude-usage.json" (builtins.toJSON dashboard);
    }
  ];
}
