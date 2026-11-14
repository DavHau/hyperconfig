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
  gateway"; hermes has no CLI interrupt). So a client that loses its
  websocket (a keepalive timeout under load, a gateway restart) does not
  end the run either: the unit then follows the session in the agent's
  state.db until its turn ends, and resumes it when a restart cut it off
  (./agent-job-follow.sh, run by ./agent-job.nix). Ending the run means stopping this unit first (or
  the follower resumes the session), then ending the turn in the
  gateway (the dashboard, or restarting hermes-agent-infra, which this
  unit no longer follows, see below). What keeps a stray turn
  from merging over a newer run is the skill: step 1 refuses to start
  while a bump workspace is in use (its liveness stamp, refreshed at each
  step and by nixpkgs-bump-nix, younger than 2 h; a file changed in the
  last 30 minutes; or a process in it), and nixpkgs-bump-guard (below) fails a push once
  someone else bumped. A dead earlier night's workspace never stops a
  run: step 1 takes it over, archives its work as a local bookmark and
  carries its fixes forward (./nixpkgs-bump/workspace.sh).

  Failures surface three ways: the report (the agent's last message) in
  ~/nixpkgs-bump/<UTC date and time>.log, the unit failing (its journal;
  `systemctl --failed` in the guest) unless the log's last line is
  `NIXPKGS-BUMP: merged` or `unchanged` (hermes' trailing `session_id:`
  line aside), and nothing on main.

  A failed unit shows as a stale recurring task (../recurring-tasks reads
  the guest's units from som's host), OnFailure= files a notice for the
  09:00 brief, and the brief says when the last run failed
  (./agent-job.nix).

  The run's toolsets are `-t terminal,file,todo,delegation,no_mcp`
  (./agent-job.nix): no skill or memory tools and no MCP servers. Its
  terminal can still write files as the infra user; this narrows, not
  forbids, persistence into later sessions. The session's cwd
  is ~/nixpkgs-bump (agent-job.nix's `--in`, the job's log dir), no
  longer ~.

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
  inputs,
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

  # Steps 2a-2c: web_search's SearXNG (flake input `searxng`, upstream
  # master) moves with nixpkgs, but only to a master tip we first saw at
  # least 72 h ago (our own record, ~/nixpkgs-bump/searxng-tips.jsonl),
  # after a code review of its diff and a search canary on som's sandbox
  # (./nixpkgs-bump/searxng.sh says how; the guard wants both for a moved
  # pin).
  searxng = import ./nixpkgs-bump/searxng.nix {
    inherit pkgs logDir bumpNix;
    # the review's parts are read through this agent's own hermes
    inherit (config.services.hyperhermes.package) hermesVenv;
  };

  # Steps 1 and 6's workspace: created and verified by facts, removed
  # with its git worktree (./nixpkgs-bump/workspace.sh says why), tested
  # by ./nixpkgs-bump/workspace-test.nix.
  workspace = import ./nixpkgs-bump/workspace.nix {
    inherit pkgs logDir;
    repo = checkout;
  };

  # som has 32 threads: at most two builds of eight cores each, half the
  # machine. Plain nix sends the guest's own (max-jobs auto = 32, cores 0:
  # all); the daemon's nix.conf values never apply to daemon clients.
  maxJobs = 2;
  cores = 8;
  # Run in a bump workspace, it also keeps that run's liveness stamp fresh
  # (nixpkgs-bump-workspace alive, every 10 minutes while nix runs: a
  # mass rebuild is one command for hours).
  bumpNix = pkgs.writeShellScriptBin "nixpkgs-bump-nix" ''
    nix=${config.nix.package}/bin/nix
    case "$PWD" in
      ${home}/hyperconfig-nixpkgs-bump-*) ;;
      *) exec $nix --max-jobs ${toString maxJobs} --cores ${toString cores} "$@" ;;
    esac
    name=''${PWD#${home}/}
    name=''${name%%/*}
    alive() { ${lib.getExe workspace} alive "$name" >/dev/null 2>&1; }
    alive
    self=$$
    (while sleep 600; do kill -0 "$self" 2>/dev/null || exit 0; alive; done) </dev/null >/dev/null 2>&1 &
    toucher=$!
    $nix --max-jobs ${toString maxJobs} --cores ${toString cores} "$@"
    rc=$?
    kill "$toucher" 2>/dev/null
    exit $rc
  '';

  # The timer, unit, log and verdict (`nixpkgs-bump-verdict`, on the
  # guest's PATH for ./test.nix): ./agent-job.nix, shared with the security
  # jobs (./security-jobs.nix). The log of the last 60 runs is kept.
  job = import ./agent-job.nix { inherit config inputs lib pkgs; } {
    name = "nixpkgs-bump";
    description = "Nightly nixpkgs-unstable bump of hyperconfig by the infra agent";
    # 01:30 at Dave's (+07): the guest has no time zone of its own (UTC),
    # so the calendar names it; systemd reads the zone from tzdata.
    # nixpkgs-unstable has usually advanced by then, and the run is done
    # by morning.
    calendar = "*-*-* 01:30:00 Asia/Bangkok";
    prompt = builtins.readFile prompt;
    promptHook = ''
      cm_pi=0
      if [ "$(TZDIR=${pkgs.tzdata}/share/zoneinfo TZ=Asia/Bangkok date +%u)" = 6 ]; then
        cm_pi=1
      fi
      if [ -e ${cmPiFlag} ]; then
        cm_pi=1
        rm -f ${cmPiFlag}
      fi
      echo "CM_PI_BUILD=$cm_pi" >>"$query"
    '';
    verdictTag = "NIXPKGS-BUMP";
    okVerdicts = [
      "merged"
      "unchanged"
    ];
    # A mass rebuild of every machine takes hours; past this the client
    # gives up. The turn itself goes on in the gateway (see above).
    timeout = "16h";
    # Hours of polling a mass rebuild outlast hermes' default of 500 tool
    # calls per turn.
    maxTurns = 3000;
    # the follower's continue message (./agent-job-follow.sh)
    resumeNote = " Never deploy.";
  };
in
lib.mkMerge [
  {
    # On the system PATH, which the gateway's commands (and subagents) end in.
    # The security jobs (./security-jobs.nix) wait for the bump's
    # ~/nixpkgs-bump/.lock before they start, so their builds never overlap.
    environment.systemPackages = [
      guard
      workspace
      bumpNix
      searxng
    ];
  }
  job
]
