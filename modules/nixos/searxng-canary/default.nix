# searxng-canary: is web_search's SearXNG (../../../hyperhermes/modules/
# browser/searxng.nix, 127.0.0.1:8890) still answering with relevant
# results? Every 10 min a oneshot sends a few fixed test queries (no user
# data) the way hermes' web_search does and writes Prometheus metrics for
# Alloy, like ../monitoring-zfs-pools.nix; the alerts live in
# ../monitoring-alerts.nix (searxng-degraded).
#
# "Relevant" is cheap on purpose (./canary.py): a query passes when one of
# its expected domains is in the top 5 result URLs, the 5 hermes keeps.
# Metrics: queries sent and relevant, results, engines answering and the
# ones SearXNG reports unresponsive/suspended (`unresponsive_engines`, per
# engine with a short class of its error), and the run's timestamp
# (staleness).
#
# ./package.nix is the script as a command, so other gates judge with the
# same queries: ./candidate.nix, the nightly bump's scratch instance of a
# candidate SearXNG build, runs it.
#
# The unit queries loopback only; the engines' traffic is searx's own
# (Mullvad egress). 4 queries per 10 min are ~1 % of the instance's load.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dir = "/run/searxng-canary";
  canary = import ./package.nix { inherit pkgs; };
in
{
  imports = [ ./candidate.nix ];

  # With searx off, Alloy's textfile block below goes too; the last .prom
  # file (RuntimeDirectoryPreserve) is removed as well, so nothing stale
  # is left to export if the collector ever comes back.
  config = lib.mkMerge [
    (lib.mkIf (!config.services.searx.enable) {
      systemd.tmpfiles.rules = [ "R ${dir} - - - -" ];
    })
    (lib.mkIf config.services.searx.enable {
      systemd.services.searxng-canary = {
        description = "Search canary against the local SearXNG, for Alloy";
        after = [ "searx.service" ];
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          RuntimeDirectory = "searxng-canary";
          RuntimeDirectoryPreserve = true;
          RuntimeDirectoryMode = "0755";
          # Loopback HTTP only.
          IPAddressAllow = [ "localhost" ];
          IPAddressDeny = "any";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
        # A failed verdict is a metric, not a failed unit (that would page
        # twice, through fleet-unit-failed too). A crash leaves the old file,
        # whose timestamp the staleness alert catches.
        script = ''
          ${lib.getExe canary} --url http://127.0.0.1:${toString config.services.searx.settings.server.port} \
            --queries 4 --pause 2 --prom ${dir}/searxng.prom || true
        '';
      };

      systemd.timers.searxng-canary = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "10min";
          RandomizedDelaySec = "1min";
        };
      };

      environment.etc."alloy/searxng-canary.alloy".text = ''
        prometheus.exporter.unix "searxng_canary" {
          set_collectors = [ "textfile" ]
          textfile {
            directory = "${dir}"
          }
        }

        prometheus.scrape "searxng_canary" {
          targets = prometheus.exporter.unix.searxng_canary.targets
          forward_to = [prometheus.relabel.searxng_canary.receiver]
          scrape_interval = "60s"
        }

        prometheus.relabel "searxng_canary" {
          forward_to = [prometheus.remote_write.mimir.receiver]

          rule {
            action = "keep"
            source_labels = ["__name__"]
            regex = "searxng_canary_.*"
          }
        }
      '';
    })
  ];
}
