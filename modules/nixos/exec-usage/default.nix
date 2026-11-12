# Exec usage: which installed programs get run, so the config can be slimmed.
#
# exec-usage.service runs ./tracer.py: bpftrace on sched:sched_process_exec
# counts uid+path in a kernel map, prints and clears it every minute; the
# tracer folds that into per-executable, per-user {count, last exec} and
# renames it into /var/lib/exec-usage/usage.json every 5 minutes. Nothing
# per exec reaches the journal. Nix build users are filtered in the kernel.
# Executables are keyed by package name without hash and version
# (`jq/bin/jq`), so history survives rebuilds and bumps.
#
# `infra-unused [--days N] [--human] [--json]` (./infra-unused.py) maps every
# environment.systemPackages entry to its executables and their last exec,
# and names the files that add it: /etc/exec-usage/package-sources.json is
# built from options.environment.systemPackages.definitionsWithLocations
# (`hyperconfig:<path>` for this repo, `<input>:<path>` for flake inputs,
# `nixpkgs:...` for NixOS defaults). Packages without bin/ are listed apart.
# From the infra space: `ssh <m>.d infra-unused`.
#
# Metrics: a timer writes `infra-unused --prom` (package counts and one
# last-used series per package) to a textfile for Alloy -> Mimir, like
# ./monitoring-zfs-pools.nix; dashboard in ./monitoring-exec-usage.nix.
#
# Extending to services later: the same usage.json can carry other kinds
# of "use" next to `exes` (e.g. units' last activation / socket hits).
{ config, lib, pkgs, options, inputs, self, ... }:
let
  cfg = config.hyper.execUsage;
  metricsDir = "/run/exec-usage-metrics";

  # Store prefix -> label, longest first so nested inputs win over self.
  roots = lib.sort (a: b: lib.stringLength a.prefix > lib.stringLength b.prefix) (
    [ { prefix = toString self.outPath; label = "hyperconfig"; } ]
    ++ lib.mapAttrsToList (n: i: { prefix = toString i.outPath; label = n; })
      (lib.filterAttrs (n: i: i ? outPath && n != "self") inputs)
    ++ [ { prefix = toString pkgs.path; label = "nixpkgs"; } ]
  );
  label = file:
    let
      f = builtins.unsafeDiscardStringContext (lib.head (lib.splitString ", via option" file));
      r = lib.findFirst (r: lib.hasPrefix r.prefix f) null roots;
    in
    if r == null then f else "${r.label}:${lib.removePrefix "/" (lib.removePrefix r.prefix f)}";

  outputsOf = p:
    lib.unique (map (o: p.${o}.outPath or p.outPath)
      (lib.intersectLists (p.outputs or [ "out" ])
        ((p.meta.outputsToInstall or [ "out" ]) ++ [ "bin" "out" ])));

  entries = lib.concatMap (d: map (p: { inherit p; file = label d.file; }) d.value)
    options.environment.systemPackages.definitionsWithLocations;
  grouped = lib.groupBy (e: builtins.unsafeDiscardStringContext e.p.outPath) entries;
  sources = lib.mapAttrsToList (_: es:
    let p = (lib.head es).p; in {
      name = p.name or "unknown";
      pname = p.pname or (builtins.parseDrvName (p.name or "unknown")).name;
      outputs = outputsOf p;
      files = lib.unique (map (e: e.file) es);
    }) grouped;

  python = pkgs.python3;
  infraUnused = pkgs.writers.writePython3Bin "infra-unused" { flakeIgnore = [ "E501" ]; }
    (builtins.readFile ./infra-unused.py);
in
{
  options.hyper.execUsage = {
    enable = lib.mkEnableOption "exec usage tracking (infra-unused)" // { default = true; };
    humanUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "dave" "grmpf" ];
      description = "Users whose execs `infra-unused --human` counts.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ infraUnused ];
    environment.etc."exec-usage/package-sources.json".text = builtins.toJSON sources;
    environment.etc."exec-usage/human-users".text = lib.concatStringsSep "\n" cfg.humanUsers + "\n";

    systemd.services.exec-usage = {
      description = "Record which executables get exec'd (for infra-unused)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${python.interpreter} -u ${./tracer.py} ${lib.getExe pkgs.bpftrace} /var/lib/exec-usage/usage.json";
        StateDirectory = "exec-usage";
        StateDirectoryMode = "0755";
        Restart = "on-failure";
        RestartSec = "30s";
        Nice = 10;
        MemoryMax = "300M";
        KillSignal = "SIGTERM";
      };
    };

    systemd.services.exec-usage-metrics = {
      description = "Write exec usage counts for Alloy";
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "exec-usage-metrics";
        RuntimeDirectoryPreserve = true;
        Nice = 10;
      };
      script = ''
        ${lib.getExe infraUnused} --prom > ${metricsDir}/exec_usage.prom.tmp
        mv ${metricsDir}/exec_usage.prom.tmp ${metricsDir}/exec_usage.prom
      '';
    };
    systemd.timers.exec-usage-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
    };

    environment.etc."alloy/exec-usage.alloy".text = ''
      prometheus.exporter.unix "exec_usage" {
        set_collectors = [ "textfile" ]
        textfile {
          directory = "${metricsDir}"
        }
      }

      prometheus.scrape "exec_usage" {
        targets = prometheus.exporter.unix.exec_usage.targets
        forward_to = [prometheus.relabel.exec_usage.receiver]
        scrape_interval = "300s"
      }

      prometheus.relabel "exec_usage" {
        forward_to = [prometheus.remote_write.mimir.receiver]

        rule {
          action = "keep"
          source_labels = [ "__name__" ]
          regex = "exec_usage_.*"
        }
      }
    '';
  };
}
