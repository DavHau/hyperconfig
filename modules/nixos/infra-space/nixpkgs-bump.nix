/*
  The nightly nixpkgs-unstable bump, run by the infra-space agent itself
  (./nixpkgs-bump/SKILL.md says what it does: bump, build every machine,
  fix, change and security review, guard, merge to main, never deploy). A
  guest module of ./hermes.nix, so it exists only where the agent runs
  (som): one bumper, as the instances share no lock.

  A systemd timer, not hermes' cron. hermes keeps cron jobs in
  ~/.hermes/cron/jobs.json (v0.22.5 cron/jobs.py:2,89), the agent's own
  mutable state (core's locked-config.nix leaves cron jobs the agent's);
  there is no declared job in config.yaml (hermes_cli/config_defaults.py
  `cron` holds scheduler settings only). Seeding that file would leave the
  schedule editable by the agent, and creating jobs needs the cronjob
  toolset, which stays in ./hermes.nix's disabled cap. A timer is Nix's
  alone; the agent cannot add, move or drop it.

  The unit is only the trigger: `hermes chat -q` (one-shot; -Q prints
  the final answer only) through the agent's `hermes` shim, which admits
  the run to the running gateway (hermes_cli/gateway_chat.py: no local
  fallback). The agent's tools run there, with the gateway's hardening,
  allowlist and cap; `oneshot` is a cli surface (gateway/session_policy.py
  SURFACES), so the run gets the same toolsets as Dave's cli sessions,
  delegation included. The skill comes preloaded (-s).

  The unit does not own the run. Stopping it, or TimeoutStartSec, kills
  the client only: the turn goes on in the gateway and may still push
  hours later (gateway_client.py:1 "Closing a viewer never stops its
  authority"; gateway_chat.py:394 "accepted work continues at the
  gateway"; hermes has no CLI interrupt). Ending the turn means ending
  it in the gateway (the dashboard, or restarting hermes-agent-infra,
  which this unit no longer follows, see below). What keeps a stray turn
  from merging over a newer run is the skill: step 1 refuses to start
  while any bump workspace exists, and nixpkgs-bump-guard (below) fails a
  push once someone else bumped.

  Failures surface three ways: the report (the agent's last message) in
  ~/nixpkgs-bump/<UTC date and time>.log, the unit failing (its journal;
  `systemctl --failed` in the guest) unless the log's last line is
  `NIXPKGS-BUMP: merged` or `unchanged` (hermes' trailing `session_id:`
  line aside), and nothing on main.

  Known gap: nothing alerts on that failed unit. The fleet's
  fleet-unit-failed alert (../monitoring-alerts.nix) reads the host's node
  exporter, which sees som's units, not the container's; the guest runs
  no exporter. Until there is a bridge, a failed night is seen in the
  dashboard (sessions, source `oneshot`), the log, or by main not moving.

  Resources: the run's nix commands go through `nixpkgs-bump-nix`, nix
  with the bump's own max-jobs and cores, so som's nix.settings and
  everyone else's builds keep theirs. Flags, not the unit: the commands
  run in the gateway, whose environment is the shim's `env -i` allowlist
  (no NIX_CONFIG from here), and systemd limits on this unit would bind
  only the shim, never the host daemon's builders. The daemon takes both
  from untrusted clients too: they are fixed fields of the client's
  wopSetOptions, applied before the trusted-users check that guards the
  other overrides (nix 2.35 src/libstore/daemon.cc ClientSettings::apply);
  `--option max-jobs` would go there and be ignored for infra, which is
  not, and must not be, a trusted user. The guard keeps plain nix: its
  only nix command is `nix flake prefetch`, a download, no build.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = "infra";
  home = "/home/${user}";
  # Only the repository: the run never works in it (the skill adds its own
  # jj workspace beside it).
  checkout = "${home}/hyperconfig";
  logDir = "${home}/nixpkgs-bump";

  prompt = pkgs.writeText "nixpkgs-bump-prompt" ''
    This is the nightly nixpkgs bump of hyperconfig, started by
    nixpkgs-bump.timer on ${config.infraSpace.member}; nobody is watching.
    Follow the nixpkgs-bump skill from step 1 to the report. Never deploy.
    Once merged, root the merged systems on the host with
    infra-space-gcroot (the skill's step 6).
    End with the skill's NIXPKGS-BUMP line.
  '';
  # cm-pi's toolchain is built from source (the skill's step 3.2): only
  # once a week, Saturday's run (01:30 at Dave's, `date +%u` = 6 in +07;
  # the guest itself runs on UTC), or when Dave
  # asks for it with ${cmPiFlag} before starting the unit by hand (the
  # run consumes the file). The skill reads the decision from the
  # prompt's CM_PI_BUILD line.
  cmPiFlag = "${logDir}/build-cm-pi";

  # The skill's last check before a push (./nixpkgs-bump/guard.sh says
  # what it checks). On the guest's PATH, so the agent's terminal finds it
  # (/run/current-system/sw/bin), and tested without network by
  # ./nixpkgs-bump/guard-test.nix.
  guard = import ./nixpkgs-bump/guard.nix {
    inherit pkgs logDir;
    nix = config.nix.package;
  };

  # The run's verdict: the report's last non-empty line, nothing earlier.
  # `hermes chat -Q` ends its output with `session_id: <id>` (on stderr,
  # which the log captures too): that line is hermes', not the report's.
  # On the guest's PATH for ./test.nix, which checks it on sample logs.
  verdict = pkgs.writeShellApplication {
    name = "nixpkgs-bump-verdict";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      [ $# = 1 ] || { echo "usage: nixpkgs-bump-verdict <log>" >&2; exit 2; }
      last=$(grep -v -e '^[[:space:]]*$' -e '^session_id: [^ ]*$' "$1" | tail -n 1 || true)
      echo "''${last:-none}"
      case "$last" in
        "NIXPKGS-BUMP: merged" | "NIXPKGS-BUMP: unchanged") exit 0 ;;
      esac
      exit 1
    '';
  };

  # som has 32 threads: at most two builds of eight cores each, half the
  # machine. Plain nix sends the guest's own (max-jobs auto = 32, cores 0:
  # all); the daemon's nix.conf values never apply to daemon clients.
  maxJobs = 2;
  cores = 8;
  bumpNix = pkgs.writeShellScriptBin "nixpkgs-bump-nix" ''
    exec ${config.nix.package}/bin/nix --max-jobs ${toString maxJobs} --cores ${toString cores} "$@"
  '';

  run = pkgs.writeShellScript "nixpkgs-bump" ''
    set -uo pipefail
    umask 077
    mkdir -p ${logDir}
    # One client at a time, also when started by hand during a run.
    exec 9>${logDir}/.lock
    if ! flock -n 9; then
      echo "nixpkgs-bump: another run holds ${logDir}/.lock" >&2
      exit 1
    fi
    log=${logDir}/$(date -u +%FT%H%MZ).log
    echo "nixpkgs-bump: report in $log"
    cm_pi=0
    if [ "$(TZDIR=${pkgs.tzdata}/share/zoneinfo TZ=Asia/Bangkok date +%u)" = 6 ]; then
      cm_pi=1
    fi
    if [ -e ${cmPiFlag} ]; then
      cm_pi=1
      rm -f ${cmPiFlag}
    fi
    query=${logDir}/last-prompt
    { cat ${prompt}; echo "CM_PI_BUILD=$cm_pi"; } >"$query"
    # The agent's shim (core's agents.nix): HERMES_HOME and the gateway's
    # environment, as in Dave's sessions. Hours of polling a mass rebuild
    # outlast hermes' default of 500 tool calls per turn. --in is home,
    # not the checkout: the run never works in the main checkout.
    /run/current-system/sw/bin/hermes chat -Q -s nixpkgs-bump --max-turns 3000 \
      --in ${home} --query-file "$query" 2>&1 | tee "$log"
    rc=''${PIPESTATUS[0]}
    # Logs of the last 60 runs.
    ls -1t ${logDir}/*.log | tail -n +61 | xargs -r rm -f
    last=$(${lib.getExe verdict} "$log") && [ "$rc" = 0 ] && exit 0
    echo "nixpkgs-bump: failed (hermes exit $rc, last line: $last); see $log" >&2
    exit 1
  '';
in
{
  # On the system PATH, which the gateway's commands (and subagents) end in.
  environment.systemPackages = [
    guard
    verdict
    bumpNix
  ];

  systemd.services.nixpkgs-bump = {
    description = "Nightly nixpkgs-unstable bump of hyperconfig by the infra agent";
    # wants, not requires: a gateway restart must not restart (re-run) the
    # bump. Nor does a switch start one.
    wants = [ "hermes-agent-${user}.service" ];
    after = [ "hermes-agent-${user}.service" ];
    restartIfChanged = false;
    # The repository is cloned at boot once GitHub answers (./guest.nix).
    unitConfig.ConditionPathExists = checkout;
    path = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.util-linux # flock
    ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      WorkingDirectory = home;
      ExecStart = run;
      # A mass rebuild of every machine takes hours; past this the client
      # gives up. The turn itself goes on in the gateway (see above).
      TimeoutStartSec = "16h";
    };
  };

  systemd.timers.nixpkgs-bump = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 01:30 at Dave's (+07): the guest has no time zone of its own (UTC),
      # so the calendar names it; systemd reads the zone from tzdata.
      # nixpkgs-unstable has usually advanced by then, and the run is done
      # by morning.
      OnCalendar = "*-*-* 01:30:00 Asia/Bangkok";
      # A night som was down runs at the next boot.
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };
}
