# "Unused packages" dashboard on the monitoring server's Grafana
# (stats.davhau.com/d/exec-usage), fed by ./exec-usage on Dave's machines:
# per machine the count of installed packages used / unused in 30 days,
# and a table of every package with its last exec and the file adding it.
# `infra-unused` on the machine itself gives the same with more detail.
{ config, lib, pkgs, ... }:
let
  ds = {
    type = "prometheus";
    uid =
      (lib.findFirst (d: d.type == "prometheus")
        (throw "monitoring-exec-usage: no prometheus datasource provisioned")
        config.services.grafana.provision.datasources.settings.datasources
      ).uid;
  };

  dashboard = {
    uid = "exec-usage";
    title = "Unused packages";
    tags = [ "exec-usage" ];
    timezone = "browser";
    schemaVersion = 39;
    refresh = "1h";
    time = { from = "now-30d"; to = "now"; };
    templating.list = [
      {
        name = "host";
        type = "query";
        datasource = ds;
        query = "label_values(exec_usage_packages, host)";
        multi = true;
        includeAll = true;
        current = { text = "All"; value = "$__all"; };
      }
    ];
    panels = [
      {
        id = 1;
        title = "Packages per machine";
        type = "table";
        datasource = ds;
        gridPos = { h = 7; w = 24; x = 0; y = 0; };
        targets = [
          {
            refId = "A";
            datasource = ds;
            expr = ''last_over_time(exec_usage_packages{host=~"$host"}[1h])'';
            instant = true;
            format = "table";
          }
          {
            refId = "B";
            datasource = ds;
            expr = ''last_over_time(exec_usage_tracking_since_timestamp_seconds{host=~"$host"}[1h]) * 1000'';
            instant = true;
            format = "table";
          }
        ];
        transformations = [
          { id = "merge"; options = { }; }
          { id = "groupingToMatrix"; options = { columnField = "state"; rowField = "host"; valueField = "Value #A"; }; }
        ];
        fieldConfig = { defaults = { unit = "short"; decimals = 0; }; overrides = [ ]; };
      }
      {
        id = 2;
        title = "Last exec per package (oldest first; empty = never since tracking began)";
        type = "table";
        datasource = ds;
        gridPos = { h = 22; w = 24; x = 0; y = 7; };
        targets = [
          {
            refId = "A";
            datasource = ds;
            expr = ''last_over_time(exec_usage_package_last_used_timestamp_seconds{host=~"$host"}[1h]) * 1000'';
            instant = true;
            format = "table";
          }
        ];
        transformations = [
          {
            id = "organize";
            options = {
              excludeByName = { Time = true; __name__ = true; instance = true; job = true; };
              renameByName = { Value = "Last exec"; };
            };
          }
        ];
        fieldConfig = {
          defaults = { };
          overrides = [
            {
              matcher = { id = "byName"; options = "Last exec"; };
              properties = [
                { id = "unit"; value = "dateTimeFromNow"; }
                { id = "noValue"; value = "never"; }
                {
                  id = "mappings";
                  value = [ { type = "range"; options = { from = 0; to = 1; result.text = "never"; }; } ];
                }
              ];
            }
          ];
        };
        options.sortBy = [ { displayName = "Last exec"; desc = false; } ];
      }
    ];
  };
in
{
  services.grafana.provision.dashboards.settings.providers = [
    {
      name = "exec-usage";
      options.path = pkgs.writeTextDir "exec-usage.json" (builtins.toJSON dashboard);
    }
  ];
}
