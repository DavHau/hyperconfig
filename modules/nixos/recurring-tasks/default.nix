/*
  Freshness of the fleet's recurring tasks: a registry (./registry.nix:
  per task its host, unit, how long since its last successful run may
  be, and how old its result may get) and, on each host with tasks, an
  exporter writing that to a textfile for Alloy -> Mimir, in
  ../monitoring-zfs-pools.nix's shape (timer -> .prom.tmp -> mv). Why:
  failed or silently stuck jobs went unseen for a week (the nightly bump:
  7 failed nights; units in the infra-space guest have no exporter, and
  nothing measured whether a "successful" job's outcome moved).

  Imported on every monitoring client (../../flake-parts/nixosConfigurations.nix);
  does nothing on a host without tasks (registry `host` = networking.hostName).

  Two units per host (./recurring_tasks.py, unit-tested at build by
  ./test_recurring_tasks.py):
    - recurring-tasks-probe, hourly, DynamicUser with network: each
      task's `result.command` (prints the unix time the current result
      was made: main's nixpkgs lastModified from GitHub, ...) into
      /run/recurring-tasks-probe/results.json.
    - recurring-tasks-metrics, every 5 min, root (it reads the journal and
      the agents' cron state): last successful run per unit from PID 1's
      own "Deactivated successfully" journal entry and the unit's state;
      `container` units are read from the host (`journalctl -M`,
      `systemctl -M`), which closes the guest's exporter gap. Plus each
      hermes agent's count of enabled and failing cron jobs (all
      profiles' jobs.json, read by a forked child running as the agent's
      user, at most 1 MiB each), no alert on those yet.
  Metrics (/run/recurring-tasks/tasks.prom): recurring_task_last_success_seconds,
  recurring_task_result_age_seconds, recurring_task_slo_seconds{kind=run|result},
  recurring_tasks_exporter_last_run_seconds, hermes_cron_jobs_{enabled,failing}.

  Alerts (../monitoring-alerts.nix, PromQL in ./promql.nix): one generic
  "Recurring task stale" warning per task (the 09:00 brief/digest), and a
  dead man's switch paging when an exporter host's timestamp stops for an
  hour; it is evaluated on edi, so it does not depend on som.
  VM test: ./test.nix (check `recurring-tasks`).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.recurringTasks;
  host = config.networking.hostName;
  mine = lib.filterAttrs (_: t: t.host == host) cfg.tasks;
  withResult = lib.filterAttrs (_: t: t.result != null) mine;
  dir = "/run/recurring-tasks";
  probeDir = "/run/recurring-tasks-probe";

  script = pkgs.writers.writePython3Bin "recurring-tasks" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./recurring_tasks.py
  );
  tested = pkgs.runCommand "recurring-tasks-tested" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp ${./recurring_tasks.py} recurring_tasks.py
    cp ${./test_recurring_tasks.py} test_recurring_tasks.py
    python3 -m unittest -v test_recurring_tasks
    ln -s ${script} $out
  '';
  bin = "${tested}/bin/recurring-tasks";

  exportConfig = pkgs.writeText "recurring-tasks-export.json" (
    builtins.toJSON {
      tasks = lib.mapAttrsToList (name: t: {
        inherit name;
        unit = t.unit;
        machine = t.container;
        run_slo = t.runSlo;
        result_slo = if t.result == null then null else t.result.slo;
      }) mine;
      probe = "${probeDir}/results.json";
      out = "${dir}/tasks.prom";
      hermes_homes = cfg.hermesHomes;
    }
  );
  probeConfig = pkgs.writeText "recurring-tasks-probe.json" (
    builtins.toJSON {
      tasks = lib.mapAttrsToList (name: t: {
        inherit name;
        inherit (t.result) command;
      }) withResult;
      out = "${probeDir}/results.json";
    }
  );

  task = lib.types.submodule {
    options = {
      host = lib.mkOption {
        type = lib.types.str;
        description = "Machine whose exporter reports the task.";
      };
      unit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "systemd unit whose successful runs count.";
      };
      container = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "nspawn guest of `host` the unit runs in.";
      };
      runSlo = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Max seconds since the unit's last successful run.";
      };
      result = lib.mkOption {
        default = null;
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              command = lib.mkOption {
                type = lib.types.str;
                description = "bash printing the unix time the current result was made (unprivileged, network).";
              };
              slo = lib.mkOption {
                type = lib.types.ints.positive;
                description = "Max age of the result in seconds.";
              };
              what = lib.mkOption {
                type = lib.types.str;
                description = "The result, in a few words (for the brief).";
              };
            };
          }
        );
      };
      repair = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Skill that repairs the task; null = by hand.";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = "infra";
      };
    };
  };

  agents = config.services.hyperhermes.agents or { };
in
{
  options.hyper.recurringTasks = {
    tasks = lib.mkOption {
      type = lib.types.attrsOf task;
      default = import ./registry.nix;
      defaultText = lib.literalExpression "import ./registry.nix";
      description = "The fleet's recurring tasks (all hosts; each host exports its own).";
    };
    hermesHomes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      # as ../hermes-agents-backup finds them
      default = lib.mapAttrs (
        a: c: if c.lockedConfig or false then "/var/lib/hermes/${a}/home" else "/var/lib/hermes/${a}/state/.hermes"
      ) agents;
      defaultText = lib.literalMD "every `services.hyperhermes.agents` entry's HERMES_HOME";
      description = "Hermes agents whose cron jobs are counted (agent -> HERMES_HOME); the name is the agent's user, whose rights the files are read with.";
    };
  };

  config = lib.mkIf (mine != { } || cfg.hermesHomes != { }) {
    assertions = lib.mapAttrsToList (name: t: {
      assertion = (t.unit != null) == (t.runSlo != null) && (t.unit != null || t.result != null);
      message = "recurring task ${name}: unit and runSlo go together, and it needs one of them or a result";
    }) mine;

    systemd.services.recurring-tasks-metrics = {
      description = "Write recurring tasks' freshness for Alloy";
      path = [ config.systemd.package ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${bin} export --config ${exportConfig}";
        RuntimeDirectory = "recurring-tasks";
        RuntimeDirectoryPreserve = true;
        TimeoutStartSec = "4min";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        # it parses files the agents write
        MemoryMax = "512M";
      };
    };
    systemd.timers.recurring-tasks-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
      };
    };

    systemd.services.recurring-tasks-probe = lib.mkIf (withResult != { }) {
      description = "Measure recurring tasks' result age";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.gnused
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${bin} probe --config ${probeConfig}";
        DynamicUser = true;
        RuntimeDirectory = "recurring-tasks-probe";
        RuntimeDirectoryPreserve = true;
        RuntimeDirectoryMode = "0755";
        TimeoutStartSec = "10min";
        ProtectHome = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        SystemCallFilter = [ "@system-service" ];
      };
    };
    systemd.timers.recurring-tasks-probe = lib.mkIf (withResult != { }) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "5min";
      };
    };

    environment.etc."alloy/recurring-tasks.alloy".text = ''
      prometheus.exporter.unix "recurring_tasks" {
        set_collectors = [ "textfile" ]
        textfile {
          directory = "${dir}"
        }
      }

      prometheus.scrape "recurring_tasks" {
        targets = prometheus.exporter.unix.recurring_tasks.targets
        forward_to = [prometheus.relabel.recurring_tasks.receiver]
        scrape_interval = "60s"
      }

      prometheus.relabel "recurring_tasks" {
        forward_to = [prometheus.remote_write.mimir.receiver]

        rule {
          action = "keep"
          source_labels = ["__name__"]
          regex = "recurring_tasks?_.*|hermes_cron_jobs_.*"
        }
      }
    '';
  };
}
