/*
  fleet-bump: the deterministic nightly nixpkgs bump (the recurring-tasks
  redesign, step 4: branch-only mode). A guest module of ../hermes.nix,
  so it runs where the agent runs (som) only. No LLM: ./fleet-bump.sh
  fetches main, moves flake.nix's nixpkgs to `channel` and the lock with
  it, builds every job of `.#fleetJobs.nightly`
  (modules/flake-parts/fleet-jobs.nix: each machine's toplevel, the
  installer's images, the weekly machines and every flake check
  evaluated), one after another, and force-pushes the result to
  `branch` (auto/nixpkgs), never to main: the bump commit plus an empty
  commit whose message lists every job's verdict and the first error
  lines of each failure (and a `Fleet-Bump-Status:` JSON trailer).

  For now it runs beside the agent-driven bump (../nixpkgs-bump.nix) and
  replaces nothing: the agent still merges, this only reports. The
  switch-over (step 5) makes it fast-forward main on green and deletes the
  agent's bump. Until then it starts at 03:30, not the agent's 01:30, and
  waits while the agent's unit is still active (`waitFor`, at most
  `waitMaxSec`, then result error), so the two rarely build at once (the
  agent's turn may outlive its unit). The wait is the script's, not an
  ExecStartPre: TimeoutStartSec is the wait's bound plus 20 h of builds.

  Never backwards: a bump whose new nixpkgs (lastModified) is older than
  main's lock (a channel switch, e.g. nixpkgs-unstable -> nixos-unstable,
  can point there) is refused, result error.

  Status, for the freshness exporter (recurring-tasks, read from the host
  as /var/lib/nixos-containers/infra-space/var/lib/fleet-bump/status.json):
    /var/lib/fleet-bump/status.json, 0644, replaced whole (rename) at the
    end of every run that got the lock, a killed one too (SIGTERM/SIGINT:
    result error):
      started, finished   UTC, ISO 8601
      channel, nixpkgs_url, nixpkgs_rev, old_nixpkgs_rev (main's)
      result              green | red | error (error: the run itself
                          failed, `error` says where; jobs may be partial)
      jobs                { <job>: "ok" | "fail" }
      errors              { <job>: [ first error line, the 9 after it ] }
      cadence, run, main_commit, candidate_commit, branch, branch_commit
  `fleet-bump --cadence weekly` (by hand; no timer yet) builds
  .#fleetJobs.weekly (cm-pi) and reports apart: status-weekly.json and
  branch `<branch>-weekly`.
  The exit status says the same: 0 green, 1 red, 2 error, 143 killed. The
  unit counts 1 (red) as success too: a red night is a verdict, not a
  broken job, and status.json carries it (the freshness registry reads
  that); fleet-unit-failed fires for error and killed only.
  75: another run holds the lock. Counted as success and nothing is
  written: no status.json, no run directory, no log beyond the journal
  line. The status left is the holder's, which writes its own when done;
  a nightly that hits the lock (a hand-started run still going at 03:30)
  is visible only as the status' age, so the freshness check must allow
  for one skipped night.

  Each run: a work tree made anew from a bare mirror (a killed run leaves
  nothing that matters), logs per job in /var/lib/fleet-bump/runs/<run>/.

  GC roots: every built job's out-link is
  /nix/var/nix/gcroots/fleet-bump/<run>/<job> in the guest, i.e. som's
  /nix/var/nix/gcroots/per-container/infra-space/fleet-bump/...: a direct
  root under the host's gcroots, which nix's GC and fast-nix-gc scan
  recursively (unlike result links under the guest's home, dangling on
  the host, ../gcroots.nix). The newest `keep` (3) runs that built
  anything keep theirs, so a red night's builds survive som's daily GC
  and the next night (or a repair) reuses them. The runtime closure is
  rooted, not the build closure.
  Deviation from the recurring-tasks design (3.1 A.3), which roots through
  the host's `infra-space-gcroot` socket (../gcroots.nix): that interface
  takes only `<machine> <nixos-system drv>` and keeps current+previous per
  machine, while the jobs here are also installer images and flake checks
  (no system drv), and a run's roots must move together per run, not per
  machine. Widening the root-owned handler for that would grow its attack
  surface; the per-container gcroots dir needs no host code and the guest
  can already root anything it builds there. Bounded by `keep` runs x the
  jobs' runtime closures (mostly shared). Revisit when step 5 replaces
  the agent's bump (the socket's cm-pi build closure then has to come
  from here).

  Push: the deploy key the agent's bump pushes main with (credential
  `github`, ../guest.nix's `Host github.com`). GitHub deploy keys write the
  whole repository, no per-branch scope; that the script pushes nothing
  but `branch` (an allowlist: auto/* only, asserted here and checked
  again by the script) is the script's. A ruleset on
  GitHub restricting main to Dave and the agent would narrow it further;
  not set up here.

  Nix: the same limits as the agent's `nixpkgs-bump-nix` (`--max-jobs 2
  --cores 8`, half of som; the daemon honours both from an untrusted
  client).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.infraSpace.fleetBump;
  stateDir = "/var/lib/fleet-bump";
  rootsDir = "/nix/var/nix/gcroots/fleet-bump";

  script = pkgs.writeShellApplication {
    name = "fleet-bump";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.git
      pkgs.openssh
      pkgs.jq
      pkgs.util-linux # flock
      config.systemd.package # systemctl is-active (waitFor)
      config.nix.package
    ];
    # the script handles failing commands itself (no errexit)
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text =
      builtins.replaceStrings
        [
          "@repo@"
          "@branch@"
          "@nixpkgsUrl@"
          "@channel@"
          "@stateDir@"
          "@rootsDir@"
          "@keep@"
          "@waitFor@"
          "@waitMax@"
          "@maxJobs@"
          "@cores@"
        ]
        (
          map lib.escapeShellArg [
            cfg.repo
            cfg.branch
            cfg.nixpkgsUrl
            cfg.channel
            stateDir
            rootsDir
            (toString cfg.keep)
          ]
          ++ [
            # the inside of a bash array: each unit quoted on its own
            (lib.escapeShellArgs cfg.waitFor)
          ]
          ++ map lib.escapeShellArg [
            (toString cfg.waitMaxSec)
            (toString cfg.maxJobs)
            (toString cfg.cores)
          ]
        )
        (builtins.readFile ./fleet-bump.sh);
  };
in
{
  options.infraSpace.fleetBump = {
    enable = lib.mkEnableOption "the deterministic nightly nixpkgs bump (branch-only)";
    channel = lib.mkOption {
      type = lib.types.str;
      # nixos-unstable: gated on Hydra's NixOS tests too, the channel for a
      # NixOS fleet (~1-3 d behind nixpkgs-unstable). Dave may switch it
      # back to "nixpkgs-unstable" (the redesign's decision 1): this line.
      default = "nixos-unstable";
      description = "nixpkgs channel (branch of NixOS/nixpkgs) the bump moves flake.nix's nixpkgs to.";
    };
    nixpkgsUrl = lib.mkOption {
      type = lib.types.str;
      default = "github:NixOS/nixpkgs/${cfg.channel}";
      defaultText = lib.literalExpression ''"github:NixOS/nixpkgs/''${channel}"'';
      description = "flake.nix's nixpkgs.url after the bump (the test points it at a local repository).";
    };
    repo = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:DavHau/hyperconfig.git";
      description = "Repository: main is fetched from it, the result pushed to `branch`.";
    };
    branch = lib.mkOption {
      type = lib.types.str;
      default = "auto/nixpkgs";
      description = "The branch the result is force-pushed to (never main).";
    };
    keep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Runs whose GC roots and logs are kept.";
    };
    maxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
    };
    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "infra";
      description = "Runs as this user (its ssh config has the deploy key).";
    };
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 03:30:00 Asia/Bangkok";
    };
    waitFor = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "nixpkgs-bump.service" ];
      description = "Units a run waits for to be inactive before it starts building (no two bumps at once).";
    };
    waitMaxSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8 * 3600;
      description = "Longest wait for `waitFor`; then the run gives up (result error). Added to the unit's 20 h build timeout.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = script;
      description = "The fleet-bump script as built (for tests).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # the script's allowlist (case auto/?*), same rule
        assertion = builtins.match "auto/.+" cfg.branch != null;
        message = "infraSpace.fleetBump.branch must be auto/<name> (branch-only mode; never main), not ${cfg.branch}";
      }
    ];

    environment.systemPackages = [ script ];

    systemd.tmpfiles.rules = [
      "d ${rootsDir} 0755 ${cfg.user} ${cfg.user} -"
    ];

    systemd.services.fleet-bump = {
      description = "Deterministic nixpkgs bump of hyperconfig (pushes ${cfg.branch}, never main)";
      wants = [ "network-online.target" ];
      # the deploy key at /run/infra-space/secrets/github (../guest.nix)
      after = [
        "network-online.target"
        "infra-space-secrets.service"
      ];
      # A switch never starts or restarts a run.
      restartIfChanged = false;
      environment = {
        GIT_SSH_COMMAND = "ssh -o BatchMode=yes";
        GIT_AUTHOR_NAME = "fleet-bump (${config.networking.hostName})";
        GIT_AUTHOR_EMAIL = "fleet-bump@${config.networking.hostName}.d";
        GIT_COMMITTER_NAME = "fleet-bump (${config.networking.hostName})";
        GIT_COMMITTER_EMAIL = "fleet-bump@${config.networking.hostName}.d";
      };
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.user;
        StateDirectory = "fleet-bump";
        StateDirectoryMode = "0755";
        WorkingDirectory = stateDir;
        ExecStart = lib.getExe script;
        # 1: red, a verdict (status.json says so); 75: another run holds
        # the lock, that one reports
        SuccessExitStatus = [
          1
          75
        ];
        # the wait for `waitFor` (the script's, bounded) plus a mass
        # rebuild of every machine, one after another; on timeout the
        # script's TERM trap writes result error
        TimeoutStartSec = toString (cfg.waitMaxSec + 20 * 3600);
      };
    };

    systemd.timers.fleet-bump = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # the guest is on UTC; systemd reads the zone from tzdata
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };
  };
}
