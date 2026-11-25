/*
  The nightly nixpkgs-unstable bump, run by the infra-space agent itself
  (./nixpkgs-bump/SKILL.md says what it does: move nixpkgs and searxng,
  make every machine build and every check evaluate, two independent
  reviews, the lock check, merge to main, never deploy). A guest module of
  ./hermes.nix, so it exists only where the agent runs (som).

  A systemd timer, not hermes' cron: cron jobs are the agent's own mutable
  state (~/.hermes/cron/jobs.json) and need the cronjob toolset, which
  stays off; a timer is Nix's alone. The unit and its log, verdict and
  OnFailure= notice are ./agent-job.nix's, shared with the security jobs.

  The unit is only a client: `hermes chat -Q` through the agent's shim,
  whose turn runs in the gateway and goes on when the client dies (a
  timeout, a lost websocket; ./agent-job-follow.sh then follows the
  session). So "is a run still going" is the gateway's answer, not the
  unit's: `nixpkgs-bump-busy` (below) asks the agent's state.db whether a
  bump session still has a turn queued or running, and if so the new run
  exits before it starts anything (no overlap; its log says
  `NIXPKGS-BUMP: skipped`, and a second skip in a row fails the unit, so
  a stuck run shows in the brief). Otherwise it starts fresh on
  main@origin; an earlier night's workspace is dropped by the skill.

  What stays, and why (the rest of the old fence went, Dave 2026-11-24):
  - nixpkgs-bump-nix: nix with the bump's own --max-jobs and --cores, so
    som's services and other agents keep their share. The daemon honours
    both from the untrusted infra client (nix's ClientSettings::apply);
    `--option max-jobs` would be ignored, and systemd limits on this unit
    bind only the shim, never the daemon's builders.
  - nixpkgs-bump-eval: the flake-check gate, one nix process per check,
    package, app, devShell and machine. One `nix flake check` held every
    machine and VM test at once (~33 GB) and was OOM-killed on som, whose
    services use ~38 of its 60 GB; per attribute the peak is one machine
    (~7 GB, som's).
  - nixpkgs-bump-guard: the lock-integrity check before the push
    (./nixpkgs-bump/guard.sh), tested by ./nixpkgs-bump/guard-test.nix.
  - nixpkgs-bump-searxng-canary: the moved SearXNG run in som's sandbox
    (../searxng-canary/candidate.nix) with the search canary; one build
    the som gate makes anyway plus a few minutes.
  - the run's toolsets (-t terminal,file,todo,delegation, no MCP;
    ./agent-job.nix): no skill or memory tools, so text an injected run
    reads cannot rewrite skills or memory through them.
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
  logDir = "${home}/nixpkgs-bump";

  prompt = ''
    This is the nightly nixpkgs bump of hyperconfig, started by
    nixpkgs-bump.timer on ${config.infraSpace.member}; nobody is watching.
    Follow the nixpkgs-bump skill to the end and do whatever it takes to
    get main onto the new nixpkgs tonight. Never deploy.
    End with the skill's NIXPKGS-BUMP line.
  '';
  # cm-pi's toolchain is built from source (~6 h): only on Saturday's run
  # (01:30 at Dave's, `date +%u` = 6 in +07; the guest runs on UTC), or
  # when ${cmPiFlag} exists (the run consumes it). A dry run (no push)
  # when ${dryRunFlag} exists. The skill reads both from the prompt.
  cmPiFlag = "${logDir}/build-cm-pi";
  dryRunFlag = "${logDir}/dry-run";

  guard = import ./nixpkgs-bump/guard.nix {
    inherit pkgs;
    nix = config.nix.package;
  };

  # som has 32 threads: at most two builds of eight cores each.
  maxJobs = 2;
  cores = 8;
  bumpNix = pkgs.writeShellScriptBin "nixpkgs-bump-nix" ''
    exec ${config.nix.package}/bin/nix --max-jobs ${toString maxJobs} --cores ${toString cores} "$@"
  '';

  evalGate = pkgs.writeShellApplication {
    name = "nixpkgs-bump-eval";
    runtimeInputs = [
      bumpNix
      pkgs.coreutils
      pkgs.jq
    ];
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = ''
      # nixpkgs-bump-eval LOGDIR, at the flake's root: what `nix flake
      # check --no-build` evaluates on x86_64-linux, one nix process per
      # attribute (this module's header says why). One line per
      # attribute, `ok` or `FAIL` with its log; exit 1 if any failed.
      [ $# = 1 ] || { echo "usage: nixpkgs-bump-eval LOGDIR" >&2; exit 2; }
      logs=$1
      mkdir -p "$logs"
      failed=0
      one() { # label attrpath
        if nixpkgs-bump-nix eval --raw ".#$2" >"$logs/$1.log" 2>&1; then
          echo "ok   $1"
        else
          echo "FAIL $1 ($logs/$1.log)"
          failed=$((failed + 1))
        fi
      }
      names() { nixpkgs-bump-nix eval --json ".#$1" --apply builtins.attrNames 2>"$logs/$1.names.log" | jq -r '.[]'; }
      for out in checks packages devShells apps nixosConfigurations; do
        attr=$out.x86_64-linux
        [ "$out" != nixosConfigurations ] || attr=$out
        list=$(names "$attr") || { echo "FAIL $attr (cannot list: $logs/$attr.names.log)"; failed=$((failed + 1)); continue; }
        for n in $list; do
          case $out in
            apps) one "$attr.$n" "$attr.\"$n\".program" ;;
            nixosConfigurations) one "$attr.$n" "$attr.\"$n\".config.system.build.toplevel.drvPath" ;;
            *) one "$attr.$n" "$attr.\"$n\".drvPath" ;;
          esac
        done
      done
      echo "nixpkgs-bump-eval: $failed failed"
      [ "$failed" = 0 ]
    '';
  };

  canary = pkgs.writeShellApplication {
    name = "nixpkgs-bump-searxng-canary";
    runtimeInputs = [
      bumpNix
      pkgs.coreutils
      pkgs.jq
      pkgs.socat
    ];
    text = ''
      # nixpkgs-bump-searxng-canary, at the flake's root: builds som's
      # SearXNG from this tree and has som run it in its sandbox
      # (../searxng-canary/candidate.nix: own uid, Mullvad egress, no
      # secrets) with the search canary. Last line PASS or FAIL.
      socket=/run/searxng-candidate/socket
      [ -S "$socket" ] || { echo "no $socket"; echo FAIL; exit 1; }
      rev=$(jq -r '.nodes[.nodes.root.inputs.searxng].locked.rev' flake.lock)
      pkg=$(nixpkgs-bump-nix build --no-link --print-out-paths \
        .#nixosConfigurations.som.config.services.searx.package | head -n 1) || { echo FAIL; exit 1; }
      reply=$(printf '%s %s\n' "$pkg" "$rev" | socat -t 960 -T 960 - "UNIX-CONNECT:$socket")
      echo "$reply"
      if [ "$(tail -n 1 <<<"$reply")" = "searxng-candidate: PASS" ]; then echo PASS; else echo FAIL; exit 1; fi
    '';
  };

  # No overlap (./nixpkgs-bump/busy.sh, tested by ./nixpkgs-bump/busy-test.nix).
  busy = import ./nixpkgs-bump/busy.nix {
    inherit pkgs;
    stateDb = "${inputs.hyperhermes.lib.lockedHermesHome user}/state.db";
    cwd = logDir;
  };

  job = import ./agent-job.nix { inherit config inputs lib pkgs; } {
    name = "nixpkgs-bump";
    description = "Nightly nixpkgs-unstable bump of hyperconfig by the infra agent";
    # 01:30 at Dave's (+07); the guest itself has no zone (UTC).
    calendar = "*-*-* 01:30:00 Asia/Bangkok";
    inherit prompt;
    busyCheck = "exec ${lib.getExe busy}";
    promptHook = ''
      cm_pi=0
      if [ "$(TZDIR=${pkgs.tzdata}/share/zoneinfo TZ=Asia/Bangkok date +%u)" = 6 ]; then
        cm_pi=1
      fi
      if [ -e ${cmPiFlag} ]; then
        cm_pi=1
        rm -f ${cmPiFlag}
      fi
      dry=0
      if [ -e ${dryRunFlag} ]; then
        dry=1
        rm -f ${dryRunFlag}
      fi
      echo "DRY_RUN=$dry" >>"$query"
      echo "CM_PI_BUILD=$cm_pi" >>"$query"
    '';
    verdictTag = "NIXPKGS-BUMP";
    okVerdicts = [
      "merged"
      "unchanged"
      "dry-run"
      # an earlier run was still going (busyCheck); twice in a row fails
      "skipped"
    ];
    # A mass rebuild of every machine takes hours; past this the client
    # gives up and the turn goes on in the gateway (see above).
    timeout = "16h";
    maxTurns = 3000;
    sharedLock = "/run/agent-jobs/nixpkgs-bump.lock";
    resumeNote = " Never deploy.";
  };
in
lib.mkMerge [
  {
    # On the system PATH, which the gateway's commands (and subagents) end
    # in. The security jobs (./security-jobs.nix) wait for this run's
    # /run/agent-jobs/nixpkgs-bump.lock, so builds never overlap.
    environment.systemPackages = [
      guard
      bumpNix
      evalGate
      canary
      busy
    ];
  }
  job
]
