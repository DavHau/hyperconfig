# Fleet alerts: Grafana unified alerting on the monitoring server (edi),
# evaluated against the Mimir datasource the clan-core monitoring service
# provisions. Trigger: som filled its ZFS pool to 0 B and nobody noticed.
#
# Rules (folder "Fleet", evaluated every minute, routed by `severity`):
#   - filesystem >= 85 % used (warning) / >= 95 % (critical), held 30 min
#   - filesystem 60-85 % used and projected to fill within 24 h (warning)
#   - always-on host sent no samples for 15 min (critical), held 15 min
#   - system service unit failed for 15 min (warning)
#   - ZFS pool not ONLINE (critical)
#   - ZFS dataset quota/refquota >= 80 % used (warning) / >= 95 % (critical),
#     held 30 min
# ZFS is judged per pool from ./monitoring-zfs-pools.nix (pool health and the
# root dataset's used/avail) plus per-dataset quota usage from the same
# exporter; per-dataset filesystem series are skipped.
#
# Every PromQL expression returns only offending series (value > 0), so an
# empty result is the healthy state: noDataState = OK. A query error (Mimir
# down) fires Grafana's DatasourceError alert instead of silently passing;
# it carries the failing rule's labels, severity included, so a warning
# rule's error is muted and shows up in the digest instead.
# Hosts that go silent are caught by absent_over_time, not by NoData.
#
# Rules with keepFiringFor (hysteresis: stays firing that long after the
# condition clears) return a value for EVERY series and threshold in B:
# a series that drops out of the result resolves at once, keepFiringFor
# only holds series that are present and below the threshold.
#
# Per-agent quotas (home/<u>, scratch/<u> of ./entity-storage) belong to
# the tenant, whose caches sit near the limit by design: home only warns,
# scratch pages only at >= 98 % for 30 min. Other datasets with a quota
# (system, slots) keep the 80 %/95 % pair.
#
# Notifications: only severity=critical goes to Telegram in real time
# (repeat once a day, with a resolved message). severity=warning is muted
# in Grafana and collected by ./monitoring-alert-digest into one message
# at 09:00 (+07). Grafana's policy tree can't do that itself: an active
# time window still flushes on group_interval ticks, and a group drops
# warnings that resolved before the window. No inhibition rules: Grafana
# provisions them only through its API, not from files, and they would
# save < 5 messages a week.
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

  # Per-agent datasets (./entity-storage): <dataset>/home/<u> (refquota)
  # and <nobackup>/scratch/<u> (quota on the subtree).
  agentHomeRe = ".*/home/[^/]+";
  agentScratchRe = ".*/scratch/[^/]+";

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

  # The query's value as a percentage. Grafana also expands annotations for
  # states without values (the Normal state an empty result maps to), where
  # .Values.A is nil and humanizePercentage fails.
  pct = "{{ with .Values.A }}{{ humanizePercentage .Value }}{{ end }}";

  # Both series carry the same dataset/kind/instance labels, so they divide
  # one-to-one; kind tells quota (used) from refquota (referenced) apart.
  quotaUsageOf =
    sel: "(zfs_dataset_quota_used_bytes{${sel}} / zfs_dataset_quota_bytes{${sel}})";
  quotaUsage = quotaUsageOf ''dataset!~"${agentHomeRe}|${agentScratchRe}"'';
  agentHomeQuota = quotaUsageOf ''dataset=~"${agentHomeRe}"'';
  agentScratchQuota = quotaUsageOf ''dataset=~"${agentScratchRe}"'';
  quotaSummary = "ZFS dataset {{ .Labels.dataset }} on {{ .Labels.instance }} is at ${pct} of its {{ .Labels.kind }}";

  # Fires only for filesystems already past 60 %: a large build writing into
  # an empty disk extrapolates to "full" without being a problem. The 6 h
  # window and 1 h `for` ride out single bursts.
  # Fires only below 85 %: above that, the usage rules already fire.
  predictFull = ''
    (((${plainUsage}) > 0.6
      and on (instance, device, mountpoint)
        predict_linear(node_filesystem_avail_bytes{${fsSel}}[6h], 86400) < 0)
    or
    (${zfsUsage} > 0.6
      and on (instance, pool)
        predict_linear(zfs_pool_avail_bytes[6h], 86400) < 0))
    unless ${usage} >= 0.85'';

  # absent_over_time copies the equality matchers into its result, so each
  # silent host comes back labelled with its instance (1). A reporting host
  # yields 0 under the same labels, so the series stays present and
  # keepFiringFor can hold it.
  hostDown = lib.concatMapStringsSep " or " (
    host:
    let
      sel = ''job="integrations/unix", instance="${host}"'';
    in
    ''absent_over_time(up{${sel}}[10m]) or count by (job, instance) (count_over_time(up{${sel}}[10m])) * 0''
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
      # Condition on A's value (B); "gt" 0 for expressions that return
      # only offending series.
      op ? "gt",
      threshold ? 0,
      keepFiringFor ? null,
    }:
    {
      inherit uid title for;
      condition = "B";
      noDataState = "OK";
      execErrState = "Error";
      labels = { inherit severity; };
      annotations = { inherit summary; };
    }
    // lib.optionalAttrs (keepFiringFor != null) { inherit keepFiringFor; }
    // {
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
                  type = op;
                  params = [ threshold ];
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
                # No upper bound: past 95 % it keeps firing next to
                # "Filesystem full" instead of resolving into it.
                expr = usage;
                op = "gte";
                threshold = 0.85;
                for = "15m";
                keepFiringFor = "30m";
                severity = "warning";
                summary = "${fsLabel} on {{ .Labels.instance }} is ${pct} full";
              })
              (rule {
                uid = "fleet-fs-full";
                title = "Filesystem full";
                # Held 30 min, so usage hovering around 95 % pages once.
                expr = usage;
                op = "gte";
                threshold = 0.95;
                for = "5m";
                keepFiringFor = "30m";
                severity = "critical";
                summary = "${fsLabel} on {{ .Labels.instance }} is ${pct} full";
              })
              (rule {
                uid = "fleet-fs-filling";
                title = "Filesystem filling up";
                expr = predictFull;
                for = "1h";
                severity = "warning";
                summary = "${fsLabel} on {{ .Labels.instance }} (${pct} full) is projected to fill within 24h";
              })
              (rule {
                uid = "fleet-host-down";
                title = "Host stopped reporting";
                # 10 min absent + 5 min for = paged after 15 min of
                # silence; held 15 min, so a flapping remote_write
                # (bam, 2026-11-08) pages once.
                expr = hostDown;
                for = "5m";
                keepFiringFor = "15m";
                severity = "critical";
                summary = "{{ .Labels.instance }} has sent no metrics for 15 minutes";
              })
              (rule {
                uid = "fleet-unit-failed";
                title = "Systemd unit failed";
                # All system units, not clan's nixos_systemd_unit_state:
                # that one only covers services.<name>.enable services, so
                # plain systemd.services failures went unseen. Coredump
                # handlers fail with the crash they record; the crashed unit
                # itself alerts.
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
              (rule {
                uid = "fleet-agent-home-quota";
                title = "Agent home quota almost full";
                expr = "${agentHomeQuota} >= 0.9";
                for = "6h";
                severity = "warning";
                summary = quotaSummary;
              })
              (rule {
                uid = "fleet-agent-scratch-quota";
                title = "Agent scratch quota almost full";
                expr = "${agentScratchQuota} >= 0.9";
                for = "6h";
                severity = "warning";
                summary = quotaSummary;
              })
              (rule {
                uid = "fleet-agent-scratch-quota-full";
                title = "Agent scratch quota full";
                # Cache churn bursts to 100 % and back by itself; only a
                # scratch full for 30 min pages.
                expr = agentScratchQuota;
                op = "gte";
                threshold = 0.98;
                for = "30m";
                keepFiringFor = "15m";
                severity = "critical";
                summary = quotaSummary;
              })
              (rule {
                uid = "fleet-zfs-quota-almost-full";
                title = "ZFS quota almost full";
                # Same no-flip pattern as the disk rules: no upper bound,
                # both held 30 min.
                expr = quotaUsage;
                op = "gte";
                threshold = 0.8;
                for = "15m";
                keepFiringFor = "30m";
                severity = "warning";
                summary = quotaSummary;
              })
              (rule {
                uid = "fleet-zfs-quota-full";
                title = "ZFS quota full";
                expr = quotaUsage;
                op = "gte";
                threshold = 0.95;
                for = "5m";
                keepFiringFor = "30m";
                severity = "critical";
                summary = quotaSummary;
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
                  # Resolved messages on: only criticals reach this
                  # contact point (warnings are muted, see policies).
                  disableResolveMessage = false;
                }
              ];
            }
          ];
        };

        # Muted all day: warnings reach Telegram only through the 09:00
        # digest (./monitoring-alert-digest). Muted alerts still show as
        # firing in Grafana.
        muteTimings.settings = {
          apiVersion = 1;
          muteTimes = [
            {
              orgId = 1;
              name = "warnings-to-digest";
              time_intervals = [
                {
                  times = [
                    {
                      start_time = "00:00";
                      end_time = "24:00";
                    }
                  ];
                }
              ];
            }
          ];
        };

        # One message per alert and host. Criticals page right away, and
        # once a day while they keep firing. Grafana's DatasourceError /
        # DatasourceNoData alerts carry the failing rule's labels, so they
        # follow its severity: a critical rule's error pages, a warning
        # rule's error is muted here and listed by the digest. Anything
        # else without a severity falls to the root route and pages.
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
              repeat_interval = "24h";
              routes = [
                {
                  receiver = "telegram";
                  object_matchers = [
                    [
                      "severity"
                      "="
                      "warning"
                    ]
                  ];
                  mute_time_intervals = [ "warnings-to-digest" ];
                }
              ];
            }
          ];
        };
      };
    })
  ];
}
