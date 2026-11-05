# Fleet alerts: Grafana unified alerting on the monitoring server (edi),
# evaluated against the Mimir datasource the clan-core monitoring service
# provisions. Trigger: som filled its ZFS pool to 0 B and nobody noticed.
#
# Rules (folder "Fleet", evaluated every minute, routed by `severity`):
#   - filesystem >= 85 % used (warning) / >= 95 % (critical)
#   - filesystem > 60 % used and projected to fill within 24 h (warning)
#   - always-on host sent no samples for 10 min (critical)
#   - system service unit failed for 15 min (warning)
#   - ZFS pool not ONLINE (critical)
# ZFS is judged per pool from ./monitoring-zfs-pools.nix (pool health and the
# root dataset's used/avail); per-dataset filesystem series are skipped.
#
# Every PromQL expression returns only offending series (value > 0), so an
# empty result is the healthy state: noDataState = OK. A query error (Mimir
# down) fires Grafana's DatasourceError alert instead of silently passing.
# Hosts that go silent are caught by absent_over_time, not by NoData.
#
# Telegram needs the grafana-telegram vars, whose generator only exists
# while hyper.monitoringAlerts.telegram.enable is set (edi sets it):
#   1. Create a bot with @BotFather, add it to the target chat, and read the
#      chat id (e.g. from https://api.telegram.org/bot<token>/getUpdates).
#   2. clan vars generate edi --generator grafana-telegram
#      (prompts for the bot token and the chat id)
#   3. clan machines update edi
# With the option off, the rules still evaluate and show in Grafana and
# notifications go to Grafana's unconfigured default contact point.
{ config, lib, ... }:
let
  cfg = config.hyper.monitoringAlerts;

  # Upstream pins the uid; look it up so a rename upstream fails loudly here.
  mimirUid =
    (lib.findFirst (d: d.type == "prometheus")
      (throw "monitoring-alerts: no prometheus datasource provisioned")
      config.services.grafana.provision.datasources.settings.datasources
    ).uid;

  # Pseudo and network filesystems: tmpfs/ramfs are sized by RAM, the rest
  # mirror space owned by another machine (nfs from bam, sshfs storagebox,
  # fuse bind views of local paths) and would alert on every client.
  # ZFS is handled per pool below.
  fsSel = ''fstype!~"zfs|tmpfs|devtmpfs|ramfs|efivarfs|overlay|squashfs|autofs|nfs.*|fuse.*"'';

  # Used share as df shows it: used / (used + avail). 1 - avail/size would
  # top out near 95 % on ext4, whose root-reserved blocks are never avail.
  # Read-only mounts never grow; /nix/store is a read-only bind of /nix.
  plainUsage = ''
    (1 - node_filesystem_avail_bytes{${fsSel}}
      / (node_filesystem_size_bytes{${fsSel}} - node_filesystem_free_bytes{${fsSel}} + node_filesystem_avail_bytes{${fsSel}}))
      unless on (instance, device, mountpoint) node_filesystem_readonly == 1'';

  # ZFS datasets share their pool's free space, so per-dataset alerts would
  # fire once per dataset and miss snapshots/unmounted datasets; the pool
  # root dataset's used + avail is the usable pool size.
  zfsUsage = "(zfs_pool_used_bytes / (zfs_pool_used_bytes + zfs_pool_avail_bytes))";

  usage = "((${plainUsage}) or ${zfsUsage})";

  # Fires only for filesystems already past 60 %: a large build writing into
  # an empty disk extrapolates to "full" without being a problem. The 6 h
  # window and 1 h `for` ride out single bursts.
  predictFull = ''
    ((${plainUsage}) > 0.6
      and on (instance, device, mountpoint)
        predict_linear(node_filesystem_avail_bytes{${fsSel}}[6h], 86400) < 0)
    or
    (${zfsUsage} > 0.6
      and on (instance, pool)
        predict_linear(zfs_pool_avail_bytes[6h], 86400) < 0)'';

  # absent_over_time copies the equality matchers into its result, so each
  # silent host comes back labelled with its instance.
  hostDown = lib.concatMapStringsSep " or " (
    host: ''absent_over_time(up{job="integrations/unix", instance="${host}"}[10m])''
  ) cfg.alwaysOn;

  fsLabel = ''{{ if .Labels.pool }}pool {{ .Labels.pool }}{{ else }}{{ .Labels.mountpoint }}{{ end }}'';

  # Annotations go through Grafana's provisioning interpolation, which
  # expands `$name` as an environment variable; the dot forms (.Labels,
  # .Values) avoid `$` entirely. Query models are passed through raw.
  rule =
    {
      uid,
      title,
      expr,
      for,
      severity,
      summary,
    }:
    {
      inherit uid title for;
      condition = "B";
      noDataState = "OK";
      execErrState = "Error";
      labels = { inherit severity; };
      annotations = { inherit summary; };
      data = [
        {
          refId = "A";
          datasourceUid = mimirUid;
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          model = {
            refId = "A";
            inherit expr;
            instant = true;
            range = false;
            datasource = {
              type = "prometheus";
              uid = mimirUid;
            };
          };
        }
        {
          refId = "B";
          datasourceUid = "__expr__";
          model = {
            refId = "B";
            type = "threshold";
            expression = "A";
            conditions = [
              {
                evaluator = {
                  type = "gt";
                  params = [ 0 ];
                };
              }
            ];
            datasource = {
              type = "__expr__";
              uid = "__expr__";
            };
          };
        }
      ];
    };

  telegram = config.clan.core.vars.generators.grafana-telegram.files;
in
{
  options.hyper.monitoringAlerts = {
    alwaysOn = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Machines expected to report around the clock. amy, vit and joy are
      # laptops and cm-pi does not run Alloy; listing them would page on
      # every lid close. edi hosts Grafana itself, so its entry only catches
      # a broken local Alloy, not edi going down.
      default = [
        "bam"
        "edi"
        "nas"
        "sgp"
        "som"
      ];
      description = "Instances whose silence for 10 minutes is a critical alert.";
    };

    telegram.enable = lib.mkEnableOption "Telegram notifications (needs the grafana-telegram vars)";
  };

  config = lib.mkMerge [
    {
      services.grafana.provision.alerting.rules.settings = {
        apiVersion = 1;
        groups = [
          {
            orgId = 1;
            name = "fleet";
            folder = "Fleet";
            interval = "1m";
            rules = [
              (rule {
                uid = "fleet-fs-almost-full";
                title = "Filesystem almost full";
                expr = "${usage} >= 0.85 < 0.95";
                for = "15m";
                severity = "warning";
                summary = "${fsLabel} on {{ .Labels.instance }} is {{ humanizePercentage .Values.A.Value }} full";
              })
              (rule {
                uid = "fleet-fs-full";
                title = "Filesystem full";
                expr = "${usage} >= 0.95";
                for = "5m";
                severity = "critical";
                summary = "${fsLabel} on {{ .Labels.instance }} is {{ humanizePercentage .Values.A.Value }} full";
              })
              (rule {
                uid = "fleet-fs-filling";
                title = "Filesystem filling up";
                expr = predictFull;
                for = "1h";
                severity = "warning";
                summary = "${fsLabel} on {{ .Labels.instance }} ({{ humanizePercentage .Values.A.Value }} full) is projected to fill within 24h";
              })
              (rule {
                uid = "fleet-host-down";
                title = "Host stopped reporting";
                expr = hostDown;
                for = "0s";
                severity = "critical";
                summary = "{{ .Labels.instance }} has sent no metrics for 10 minutes";
              })
              (rule {
                uid = "fleet-unit-failed";
                title = "Systemd unit failed";
                # All system units, not clan's nixos_systemd_unit_state:
                # that one only covers services.<name>.enable services, and
                # som's nixpkgs-bump (plain systemd.services) failed for
                # days unseen. Coredump handlers fail with the crash they
                # record; the crashed unit itself alerts.
                expr = ''node_systemd_unit_state{state="failed", name!~"systemd-coredump@.*"} == 1'';
                for = "15m";
                severity = "warning";
                summary = "{{ .Labels.name }} on {{ .Labels.instance }} has failed";
              })
              (rule {
                uid = "fleet-zpool-unhealthy";
                title = "ZFS pool not online";
                expr = ''node_zfs_zpool_state{state!="online"} == 1'';
                for = "5m";
                severity = "critical";
                summary = "ZFS pool {{ .Labels.zpool }} on {{ .Labels.instance }} is {{ .Labels.state }}";
              })
            ];
          }
        ];
      };
    }

    (lib.mkIf cfg.telegram.enable {
      clan.core.vars.generators.grafana-telegram = {
        prompts.bot-token = {
          description = "Telegram bot token for Grafana alerts (from @BotFather)";
          type = "hidden";
          persist = true;
        };
        prompts.chat-id = {
          description = "Telegram chat id Grafana alerts are sent to";
          type = "hidden";
          persist = true;
        };
      };

      systemd.services.grafana.serviceConfig.LoadCredential = [
        "telegram-bot-token:${telegram.bot-token.path}"
        "telegram-chat-id:${telegram.chat-id.path}"
      ];

      services.grafana.provision.alerting = {
        contactPoints.settings = {
          apiVersion = 1;
          contactPoints = [
            {
              orgId = 1;
              name = "telegram";
              receivers = [
                {
                  uid = "telegram";
                  type = "telegram";
                  # Contact point settings are interpolated, unlike rule
                  # queries: $__file reads the credential at provisioning.
                  settings = {
                    bottoken = "$__file{/run/credentials/grafana.service/telegram-bot-token}";
                    chatid = "$__file{/run/credentials/grafana.service/telegram-chat-id}";
                  };
                }
              ];
            }
          ];
        };

        # One message per alert and host; warning and critical both go out.
        policies.settings = {
          apiVersion = 1;
          policies = [
            {
              orgId = 1;
              receiver = "telegram";
              group_by = [
                "alertname"
                "instance"
              ];
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "4h";
            }
          ];
        };
      };
    })
  ];
}
