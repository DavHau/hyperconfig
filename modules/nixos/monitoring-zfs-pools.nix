# Pushes ZFS pool health and capacity to Mimir for ./monitoring-alerts.nix.
#
# Capacity: node_filesystem_* only sees mounted datasets, and statfs on a
# dataset reports its own referenced bytes plus the pool's free space, so
# snapshots, zvols and unmounted datasets are invisible (nas: 0.7 % "used"
# from mounts vs 49 % real). The pool's root dataset `used` covers all of
# them and `avail` is what writes actually get (after parity and slop), so
# a timer writes both to a textfile for Alloy.
#
# Quotas: datasets with a quota (incl. children, snapshots) or refquota
# (own referenced bytes) hit EDQUOT long before the pool fills, so the same
# timer exports each set limit with the usage it is checked against
# (quota ↔ used, refquota ↔ referenced) from a single `zfs get`.
#
# Health: the zfs collector's node_zfs_zpool_state, read from kstat.
#
# The clan-core monitoring client hardcodes its unix exporter collectors; Alloy
# runs `alloy run /etc/alloy` and merges every *.alloy file there into one
# config, so a second file can add its own exporter and reuse the upstream
# `prometheus.remote_write.mimir` component without forking the service.
# Only the pool and quota series are kept: the zfs collector otherwise emits a few
# hundred ARC/dataset counters per host that nothing here looks at.
{ config, lib, pkgs, ... }:
let
  dir = "/run/zfs-pool-metrics";
in
{
  config = lib.mkIf config.boot.zfs.enabled {
    systemd.services.zfs-pool-metrics = {
      description = "Write ZFS pool capacity and dataset quotas for Alloy";
      path = [
        config.boot.zfs.package
        pkgs.gawk
      ];
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "zfs-pool-metrics";
        RuntimeDirectoryPreserve = true;
      };
      # Renamed into place so Alloy never reads a half-written file.
      script = ''
        set -o pipefail
        zfs list -Hp -d 0 -o name,used,avail | awk -F'\t' '
          { used[$1] = $2; avail[$1] = $3 }
          END {
            print "# TYPE zfs_pool_used_bytes gauge"
            for (p in used) printf "zfs_pool_used_bytes{pool=\"%s\"} %s\n", p, used[p]
            print "# TYPE zfs_pool_avail_bytes gauge"
            for (p in avail) printf "zfs_pool_avail_bytes{pool=\"%s\"} %s\n", p, avail[p]
          }' > ${dir}/pools.prom.tmp
        # -p prints an unset quota as 0; "none"/"-" are guarded for safety.
        # Samples are buffered so each family stays contiguous under its TYPE.
        zfs get -Hp -t filesystem -o name,property,value quota,refquota,used,referenced | awk -F'\t' '
          function set(x) { return x != "" && x != "0" && x != "none" && x != "-" }
          { v[$1, $2] = $3; ds[$1] = 1 }
          END {
            for (d in ds) {
              if (set(v[d, "quota"])) {
                lim = lim sprintf("zfs_dataset_quota_bytes{dataset=\"%s\",kind=\"quota\"} %s\n", d, v[d, "quota"])
                use = use sprintf("zfs_dataset_quota_used_bytes{dataset=\"%s\",kind=\"quota\"} %s\n", d, v[d, "used"])
              }
              if (set(v[d, "refquota"])) {
                lim = lim sprintf("zfs_dataset_quota_bytes{dataset=\"%s\",kind=\"refquota\"} %s\n", d, v[d, "refquota"])
                use = use sprintf("zfs_dataset_quota_used_bytes{dataset=\"%s\",kind=\"refquota\"} %s\n", d, v[d, "referenced"])
              }
            }
            print "# TYPE zfs_dataset_quota_bytes gauge"
            printf "%s", lim
            print "# TYPE zfs_dataset_quota_used_bytes gauge"
            printf "%s", use
          }' > ${dir}/datasets.prom.tmp
        mv ${dir}/pools.prom.tmp ${dir}/pools.prom
        mv ${dir}/datasets.prom.tmp ${dir}/datasets.prom
      '';
    };

    systemd.timers.zfs-pool-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };

    environment.etc."alloy/zfs.alloy".text = ''
      prometheus.exporter.unix "zfs" {
        set_collectors = [ "zfs", "textfile" ]
        textfile {
          directory = "${dir}"
        }
      }

      prometheus.scrape "zfs" {
        targets = prometheus.exporter.unix.zfs.targets
        forward_to = [prometheus.relabel.zfs_pools.receiver]
        scrape_interval = "60s"
      }

      prometheus.relabel "zfs_pools" {
        forward_to = [prometheus.remote_write.mimir.receiver]

        rule {
          action = "keep"
          source_labels = ["__name__"]
          regex = "node_zfs_zpool_state|zfs_pool_(used|avail)_bytes|zfs_dataset_quota_(used_)?bytes"
        }
      }
    '';
  };
}
