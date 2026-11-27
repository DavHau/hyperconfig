# Local overrides for the clan-core monitoring client (Alloy -> Mimir/Loki).
#
# The clan-core service writes /etc/alloy/config.alloy as one fixed string
# with Alloy's defaults: a 10 s scrape, 30 s/10 s request timeouts, retries
# every 30 ms..5 s, up to 50 shards, 2000-sample and 1 MiB batches, a WAL kept
# for 8 h, and Loki batches dropped after 10 failed tries. On a roaming
# laptop's slow link (4G, 240-700 ms RTT, loss) a push that runs into the
# deadline is resent whole, so the same bytes went up again and again: amy
# sent ~5.5 KB/s with 37 % of its samples retried, and Loki dropped 238k
# entries. This module patches that string (every patch must apply, or
# evaluation fails, so an upstream change can't silently undo it):
#
# Every machine:
#   - scrape every 15 s instead of 10 s;
#   - request timeouts of 2 min (Mimir and Loki), retries backing off
#     1 s..2 min (Loki 1 s..5 min), and Loki retries without a cap: the journal is the buffer
#     (a full queue just pauses reading it), so an outage no longer drops
#     logs after ten tries.
# Frugal machines (`hyper.monitoringClient.frugal`, default: roaming
# laptops, `hyper.selfHeal.roaming` in ./self-heal):
#   - scrape every 60 s; one shard; 1000-sample / 128 KiB batches sent at
#     most once a minute, with a 5 min timeout, so one push fits a slow link
#     and finishes instead of being cut and resent; backoff 30 s..10 min;
#   - a bounded backlog: samples and journal entries older than 2 h are
#     dropped instead of pushed after a long offline stretch (WAL
#     max_keepalive_time, sample_age_limit, the journal's max_age and a
#     Loki stage.drop);
#   - fewer series: only what ./monitoring-alerts.nix and the clan
#     dashboard read (see `dropSeries` below);
#   - fewer log lines: debug lines (journal priority or an in-line DEBUG
#     level), yggdrasil's per-peer connect/disconnect lines, netlink event
#     dumps, cloudflare-warp's IPC chatter, then at most 0.2 lines/s per unit
#     (burst 300).
# Compression: remote_write and Loki pushes are snappy-compressed protobuf
# by protocol; Alloy offers nothing better for either. TCP keepalive (30 s)
# and idle connections (closed after 5 min) are Alloy's fixed defaults.
# Budget on amy: ~670 samples/min at ~21 B each (~0.25 KB/s) and a few
# hundred log lines/h, against 2400 series every 10 s and 1.8 MB/h of
# cloudflare-warp debug lines before. Cost: the clan dashboard's CPU panel
# (`rate(...[1m])`) needs two samples a minute, so it stays empty for
# frugal machines; the alerts all use windows of 10 min or more.
# Loki's backlog is bounded too: loki.write queues at most 10 MiB / 128 KiB
# = 80 batches (about one a minute), then stops reading the journal; on
# reconnect stage.drop discards what has grown older than 2 h, and the rate
# limit (wall-clock) replays at most ~300 lines per unit. Restarting Alloy
# while offline loses the queued batches (the journal cursor has moved on;
# Loki's WAL is experimental); suspend keeps them.
#
# The receiving side (./monitoring-server.nix, edi) takes late samples:
# Mimir's out-of-order window is 8 d (./monitoring-teamclaude), Loki
# accepts entries up to a week old (reject_old_samples_max_age), in order
# per stream, which a blocked journal reader keeps.
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.monitoringClient;
  frugal = cfg.frugal;

  # Replace `from` by `to` in `text`, failing evaluation if `from` is not
  # there exactly once.
  patch =
    text:
    { from, to }:
    let
      parts = lib.splitString from text;
    in
    if lib.length parts != 2 then
      throw "monitoring-client.nix: expected exactly one `${from}` in the clan-core Alloy config, found ${toString (lib.length parts - 1)}"
    else
      lib.concatStringsSep to parts;

  # Inserted into upstream's `endpoint {` blocks.
  indent = text: lib.concatMapStrings (l: if l == "" then "\n" else "    ${l}\n") (lib.splitString "\n" text);

  # Series the laptops don't send. Kept: node_filesystem_{avail,free,size}_bytes
  # and _readonly (filesystem alerts, dashboard), node_memory_Mem{Available,
  # Total}_bytes and Swap{Free,Total} (dashboard), node_cpu_seconds_total
  # mode=idle (the dashboard's CPU panel), node_systemd_unit_state for
  # state=failed (the unit-failed alert), nixos_systemd_unit_state (dashboard),
  # up, and everything of the other *.alloy files (zfs, selfheal,
  # exec-usage, recurring tasks).
  dropSeries = lib.concatStringsSep "|" [
    "node_systemd_(socket|timer)_.*"
    "node_filesystem_(files|files_free|device_error)"
    "node_scrape_collector_.*"
    "node_exporter_build_info"
    "node_textfile_mtime_seconds"
    "promhttp_.*"
    "scrape_.*"
  ];

  remoteWriteEndpoint =
    if frugal then
      ''
        remote_timeout = "5m"
        queue_config {
          capacity = 5000
          max_samples_per_send = 1000
          batch_send_deadline = "60s"
          min_shards = 1
          max_shards = 1
          min_backoff = "30s"
          max_backoff = "10m"
          retry_on_http_429 = true
          sample_age_limit = "2h"
        }
        write_relabel_config {
          source_labels = ["__name__"]
          regex = "${dropSeries}"
          action = "drop"
        }
        // Mark the few series of a family that are kept, drop the rest.
        write_relabel_config {
          source_labels = ["__name__", "mode", "state"]
          regex = "node_cpu_seconds_total;idle;|node_systemd_unit_state;;failed|node_memory_(MemAvailable|MemTotal|SwapFree|SwapTotal)_bytes;;"
          target_label = "frugal_keep"
          replacement = "1"
        }
        write_relabel_config {
          source_labels = ["__name__", "frugal_keep"]
          regex = "(node_cpu_seconds_total|node_systemd_unit_state|node_memory_.*);"
          action = "drop"
        }
        write_relabel_config {
          regex = "frugal_keep"
          action = "labeldrop"
        }
      ''
    else
      ''
        remote_timeout = "2m"
        queue_config {
          min_backoff = "1s"
          max_backoff = "2m"
          retry_on_http_429 = true
        }
      '';

  lokiEndpoint =
    if frugal then
      ''
        remote_timeout = "5m"
        batch_size = "128KiB"
        batch_wait = "60s"
        min_backoff_period = "30s"
        max_backoff_period = "10m"
        max_backoff_retries = 0
        retry_on_http_429 = true
      ''
    else
      ''
        remote_timeout = "2m"
        min_backoff_period = "1s"
        max_backoff_period = "5m"
        max_backoff_retries = 0
        retry_on_http_429 = true
      '';

  patches = [
    {
      from = ''scrape_interval = "10s"'';
      to = ''scrape_interval = "${if frugal then "60s" else "15s"}"'';
    }
    {
      from = ''/mimir/api/v1/push"'';
      to = ''/mimir/api/v1/push"'' + "\n" + indent remoteWriteEndpoint;
    }
    {
      from = ''/loki/loki/api/v1/push"'';
      to = ''/loki/loki/api/v1/push"'' + "\n" + indent lokiEndpoint;
    }
  ]
  ++ lib.optionals frugal [
    {
      from = ''prometheus.remote_write "mimir" {'';
      to = ''
        prometheus.remote_write "mimir" {
          wal {
            truncate_frequency = "30m"
            max_keepalive_time = "2h"
          }
      '';
    }
    {
      from = "relabel_rules = loki.relabel.journal.rules";
      to = ''
        relabel_rules = loki.relabel.journal.rules
          max_age = "2h"'';
    }
    {
      from = "forward_to = [loki.write.loki.receiver]";
      to = "forward_to = [loki.process.frugal.receiver]";
    }
  ];

  upstream = builtins.readFile config.services.alloy.configPath;
  patched = lib.foldl' patch upstream patches;
in
{
  options.hyper.monitoringClient.frugal = lib.mkOption {
    type = lib.types.bool;
    default = config.hyper.selfHeal.roaming or false;
    defaultText = lib.literalExpression "config.hyper.selfHeal.roaming";
    description = ''
      Send as little as possible, in pushes small enough for a slow link:
      60 s scrapes, fewer series and log lines, one shard, a 2 h backlog
      (see the header of modules/nixos/monitoring-client.nix).
    '';
  };

  config = {
    environment.etc."alloy/config.alloy".source = lib.mkForce (pkgs.writeText "config.alloy" patched);

    environment.etc."alloy/journal-frugal.alloy" = lib.mkIf frugal {
      text = ''
        loki.process "frugal" {
          forward_to = [loki.write.loki.receiver]

          // A backlog older than 2 h is not worth the uplink.
          stage.drop {
            older_than = "2h"
            drop_counter_reason = "too_old"
          }
          stage.match {
            selector = "{level=\"debug\"}"
            action = "drop"
            drop_counter_reason = "debug"
          }
          // Daemons that log at info but tag the line DEBUG (cloudflare-warp).
          stage.drop {
            expression = "^\\S+\\s+(\\x1b\\[[0-9;]*m)?DEBUG(\\s|\\x1b)"
            drop_counter_reason = "debug"
          }
          stage.match {
            selector = "{service_name=\"yggdrasil.service\"} |~ \"(Connected|Disconnected) (inbound|outbound): \""
            action = "drop"
            drop_counter_reason = "noisy"
          }
          // rtnetlink event dumps (cloudflare-warp: one per neighbour/route
          // change) and its per-client IPC chatter.
          stage.drop {
            expression = "^(New|Del)(Neighbour|Route|Address|Link)[;(]|IPC: new connection|IPC reader task finished"
            drop_counter_reason = "noisy"
          }
          stage.limit {
            rate = 0.2
            burst = 300
            by_label_name = "service_name"
            drop = true
          }
        }
      '';
    };
  };
}
