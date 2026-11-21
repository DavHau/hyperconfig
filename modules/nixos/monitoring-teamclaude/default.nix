# "TeamClaude usage" dashboard on the monitoring server's Grafana
# (stats.davhau.com/d/teamclaude-usage) and the usage pages at
# stats.davhau.com/usage/, both fed by som's exporter
# (../teamclaude-gateway/metrics.nix).
#
# The usage pages (./site, three views to pick from) show who used how
# much of the pooled Claude Max 20x accounts, in % of one account's weekly
# quota, per day / week / month, with the pool's capacity and what is left.
# ./ledger.py (a timer here) derives that from Mimir: each account's weekly
# utilization as Anthropic reports it, split among the clients by what they
# spent on that account (its header says how, and how exact it is). It
# writes data.json; the pages are static and read it. They are behind
# Grafana's own sign-in (pocket-id, group `stats`: Dave): nginx asks
# Grafana's /api/user with the visitor's session cookie (auth_request) and
# sends anyone without one to Grafana's login, which returns here.
# The pages are the privacy boundary, not the data: the per-client numbers
# behind them are Mimir series like every other metric (readable by whoever
# can query Mimir: edi's loopback, the fleet's metrics push credential).
#
# The dashboard: per client key output tokens and
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
  grafanaPort = config.services.grafana.settings.server.http_port;
  # The ledger's own copy (history beyond Mimir's 30 days is merged from it).
  ledgerState = "/var/lib/monitoring-teamclaude/data.json";
  # What nginx serves; group nginx, nothing else can read it.
  publicDir = "/run/monitoring-teamclaude";
  site = pkgs.runCommand "monitoring-teamclaude-site" { } ''
    mkdir -p $out
    cp ${./site}/*.html ${./site}/*.js ${./site}/*.css $out/
  '';
  mimir = "http://127.0.0.1:3001/mimir/prometheus/api/v1";

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
    links = [
      {
        title = "Usage in % of an account";
        type = "link";
        url = "/usage/";
        targetBlank = false;
      }
    ];
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

  users.users.monitoring-teamclaude = {
    isSystemUser = true;
    group = "nginx";
  };

  systemd.services.monitoring-teamclaude = {
    description = "TeamClaude usage ledger for the usage pages";
    after = [ "mimir.service" ];
    serviceConfig = {
      Type = "oneshot";
      # A static user, not DynamicUser: with DynamicUser systemd puts the
      # RuntimeDirectory under /run/private (0700 root), and nginx can't
      # reach data.json there (403 on every page).
      User = "monitoring-teamclaude";
      Group = "nginx";
      StateDirectory = "monitoring-teamclaude";
      RuntimeDirectory = "monitoring-teamclaude";
      RuntimeDirectoryMode = "0750";
      RuntimeDirectoryPreserve = true;
      UMask = "0027";
      # Group nginx is only for handing nginx data.json; keep the unit away
      # from what else that group can read (TLS keys, nginx credentials).
      InaccessiblePaths = [ "-/var/lib/acme" "-/run/nginx" "-/etc/nginx" ];
      IPAddressAllow = "localhost";
      IPAddressDeny = "any";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      SystemCallArchitectures = "native";
    };
    script = ''
      ${lib.getExe pkgs.python3} ${./ledger.py} --mimir ${mimir} --out ${ledgerState}
      cp ${ledgerState} ${publicDir}/data.json.tmp
      mv ${publicDir}/data.json.tmp ${publicDir}/data.json
    '';
  };

  systemd.timers.monitoring-teamclaude = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "15min";
    };
  };

  services.nginx.virtualHosts.${config.services.grafana.settings.server.domain}.locations = {
    # Signed in = Grafana knows the session cookie. Any other credential
    # (an API token, basic auth of the local admin) is dropped, so only a
    # browser session of a `stats` member opens the pages.
    "= /_teamclaude_usage_auth" = {
      proxyPass = "http://127.0.0.1:${toString grafanaPort}/api/user";
      extraConfig = ''
        internal;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Authorization "";
        proxy_set_header X-Grafana-Org-Id "";
      '';
    };
    "@teamclaude_usage_login".return = "302 /login?redirectTo=%2Fusage%2F";
    "= /usage".return = "301 /usage/";
    "^~ /usage/" = {
      alias = "${site}/";
      extraConfig = ''
        auth_request /_teamclaude_usage_auth;
        error_page 401 = @teamclaude_usage_login;
        add_header Cache-Control "private, no-store" always;
        add_header X-Content-Type-Options nosniff always;
        add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'" always;
      '';
    };
    "= /usage/data.json" = {
      alias = "${publicDir}/data.json";
      extraConfig = ''
        auth_request /_teamclaude_usage_auth;
        error_page 401 = @teamclaude_usage_login;
        add_header Cache-Control "private, no-store" always;
        add_header X-Content-Type-Options nosniff always;
      '';
    };
  };

  services.grafana.provision.dashboards.settings.providers = [
    {
      name = "teamclaude";
      options.path = pkgs.writeTextDir "teamclaude-usage.json" (builtins.toJSON dashboard);
    }
  ];
}
