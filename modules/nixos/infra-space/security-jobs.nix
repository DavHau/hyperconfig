/*
  The infra-space agent's unattended security jobs, beside the nightly
  nixpkgs bump (./nixpkgs-bump.nix) and built the same way
  (./agent-job.nix: timer -> `hermes chat -Q -s <skill>` through the
  agent's shim, log and verdict per run; a guest module of ./hermes.nix,
  so on som only). Each job's SKILL.md (./security-jobs/<job>/) is its
  instructions, with Dave's policy (./security-jobs/policy.md) spliced in
  verbatim:

    cve-watch       daily 02:30 Asia/Bangkok: new/updated CVEs and
                    advisories of the last 48 h against what the fleet
                    runs; fixes (or takes down) per policy
    hygiene-report  Saturday 03:30 Asia/Bangkok (Dave: one weekly job per
                    night): the repo's hygiene lint (checks.hygiene,
                    tools/hygiene) plus duplicated mechanisms by hand,
                    mechanical fixes landed, structural ones decided
    security-audit  Sunday 03:30 Asia/Bangkok, on the code the hygiene
                    run cleaned: configuration and exposure mistakes,
                    diffed against last week's report

  No overlap with the 01:30 bump nor with each other: every job is
  ordered after nixpkgs-bump.service and lets a bump that is due within
  20 min start first (missed nights fire both Persistent= timers at
  boot), waits for the bump's lock (~/nixpkgs-bump/.lock), and all three share
  ~/.sec-jobs.lock (one security job at a time); a job still waiting
  after 4 h starts with BUSY in its prompt and builds nothing heavy
  (agent-job.nix).

  Reporting (policy rule 5): the run's last message is its report, in
  ~/<job>/<UTC date>T<HHMM>Z.log and the dashboard's sessions (Automation,
  source `oneshot`), the channel the bump reports through. A run that ends
  with a quiet verdict (cve-watch `quiet`) has its session archived, so a
  quiet night sends Dave nothing; the log stays. Decisions go to the
  fleet's registry through its CLI (`decision`, ./decisions.nix): ones a
  job made itself as `decided`, questions only past Dave's bar (money,
  identity, irreversible, access, noticeable, conflict) as `add
  --needs-dave`, takedowns and mitigations of protected services as
  `notice`, which the 09:00 brief carries (policy.md says how).

  What the runs may do (policy rule 1: fix -> security review -> land ->
  deploy -> verify) and the helpers for it, on the guest's PATH:
    sec-<job>-workspace  the job's own jj workspace (./nixpkgs-bump's
                         workspace helper, built with the job's prefix)
    sec-job-guard        pre-push check of the exact commits
                         (./security-jobs/guard.sh; check sec-job-guard)
    sec-job-deploy       detached deploy of the pushed rev: one build,
                         parallel switches, som last, rollback watchdog
    sec-job-nix          nix with the jobs' --max-jobs 2 --cores 8
    sec-collect          read-only inventory/exposure/tripwire collectors
    sec-cve-feeds        NVD + GHSA window matched against the inventory
  Takedowns are data in ../security-takedown/takedowns.nix (fleet-wide
  module; only units a machine declares takedown-eligible, its
  internet-exposed apps, pass eval). Never locking Dave out has these
  mechanical layers: that allowlist; sec-job-guard, whose primary check
  evaluates ./security-jobs/protected.nix on every machine before and
  after the push and refuses any difference (network, firewall, DNS,
  sshd, users, PAM, boot, file systems, nix trust, the protected units'
  text and wantedBy, the set of units, the takedown allowlist; a
  takedown of an eligible unit is the one change it lets through), with
  path and line checks as a cheap pre-filter (also: more than one
  takedown a night, flake inputs outside a short movable list, skills/
  and agent-instruction files); sec-job-deploy's rollback watchdog on
  each target (reverts unless ssh, and pocket-id on its host, pass after
  the switch; som switches last). The runs' toolsets
  (`-t terminal,file,todo,delegation,no_mcp`) give them no skill or
  memory tools and no MCP servers; their terminal can still write files
  as the infra user, so this narrows, not forbids, persistence: the
  repo's skills/ is guard-denied, and ~/skills / the agent's memories
  are not write-protected (the tools run in the gateway's process,
  outside the job unit, so a ReadOnlyPaths= on the job unit would not
  reach them).
  The review subagent the skills require is briefed by the run itself:
  it catches the run's mistakes, not an injected run.

  A failed night: the unit fails (a stale recurring task: each job is in
  ../../recurring-tasks/registry.nix, read from som's host), OnFailure=
  files a notice and
  the 09:00 brief lists any job whose last run failed (./agent-job.nix).
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
  checkout = "${home}/hyperconfig";
  dir = ./security-jobs;
  bumpLock = "${home}/nixpkgs-bump/.lock";
  sharedLock = "${home}/.sec-jobs.lock";

  # The deployable fleet, explicit (the installer is no running system).
  # Every job's SKILL.md gets it through @MACHINES@; the eval check in each
  # skill fails the run on a machine not named here.
  machines = [
    "amy"
    "bam"
    "cm-pi"
    "edi"
    "joy"
    "nas"
    "sgp"
    "som"
    "vit"
  ];
  machinesStr = lib.concatStringsSep " " machines;

  maxJobs = 2;
  cores = 8;
  jobNix = pkgs.writeShellScriptBin "sec-job-nix" ''
    exec ${config.nix.package}/bin/nix --max-jobs ${toString maxJobs} --cores ${toString cores} "$@"
  '';

  workspace =
    job:
    import ./nixpkgs-bump/workspace.nix {
      inherit pkgs;
      repo = checkout;
      logDir = "${home}/${job}";
      name = "sec-${job}-workspace";
      prefix = "hyperconfig-sec-${job}-";
    };

  # The guard's evaluation check (./security-jobs/protected-check.sh):
  # ./security-jobs/protected.nix on every machine of main@origin and @.
  protectedCheck = pkgs.writeShellApplication {
    name = "sec-job-protected-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      config.nix.package
    ];
    text = builtins.replaceStrings [ "@protected@" ] [ "${./security-jobs/protected.nix}" ] (
      builtins.readFile ./security-jobs/protected-check.sh
    );
  };

  guard = pkgs.writeShellApplication {
    name = "sec-job-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gawk
      pkgs.jq
      pkgs.jujutsu
      protectedCheck
    ];
    text = builtins.readFile ./security-jobs/guard.sh;
  };

  deploy = pkgs.writeShellApplication {
    name = "sec-job-deploy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.git
      pkgs.gnugrep
      pkgs.jq
      pkgs.openssh
      pkgs.systemd
    ];
    text =
      builtins.replaceStrings
        [ "@machines@" "@repo@" "@maxJobs@" "@cores@" "@jobNix@" ]
        [ machinesStr checkout (toString maxJobs) (toString cores) (lib.getExe' jobNix "sec-job-nix") ]
        (builtins.readFile ./security-jobs/deploy.sh);
  };

  collect = pkgs.writeShellApplication {
    name = "sec-collect";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.git
      pkgs.jq
      pkgs.openssh
      pkgs.vulnix
      config.nix.package
    ];
    # sec-job-nix for every evaluation (limits apply to IFD builds too)
    text = ''
      NIX=${lib.getExe' jobNix "sec-job-nix"}
    ''
    + builtins.replaceStrings [ "@machines@" ] [ machinesStr ] (
      builtins.readFile ./security-jobs/collect.sh
    );
  };

  feeds = pkgs.writers.writePython3Bin "sec-cve-feeds" { doCheck = false; } (
    builtins.replaceStrings [ "@watchlist@" ] [ "${./security-jobs/watchlist.json}" ] (
      builtins.readFile ./security-jobs/cve_feeds.py
    )
  );

  # A job's SKILL.md: its own text with the policy (./security-jobs/
  # policy.md), the ground rules (./security-jobs/common.md, `<job>` there
  # the job's name), the machine list and the member substituted.
  # The shared sections first (common.md names @MACHINES@ itself).
  skillText =
    job:
    builtins.replaceStrings [ "@MACHINES@" "@MEMBER@" "<job>" ]
      [ machinesStr config.infraSpace.member job ]
      (
        builtins.replaceStrings [ "@POLICY@" "@COMMON@" ] [
          (builtins.readFile ./security-jobs/policy.md)
          (builtins.readFile ./security-jobs/common.md)
        ] (builtins.readFile (dir + "/${job}/SKILL.md"))
      );

  mkJob =
    {
      job,
      description,
      calendar,
      tag,
      okVerdicts,
      quietVerdicts ? [ ],
      timeout,
    }:
    import ./agent-job.nix { inherit config inputs lib pkgs; } {
      name = job;
      inherit
        description
        calendar
        okVerdicts
        quietVerdicts
        timeout
        sharedLock
        ;
      verdictTag = tag;
      waitFor = [ bumpLock ];
      # Missed nights: the bump goes first (agent-job.nix `after`).
      after = [ "nixpkgs-bump.service" ];
      prompt = ''
        This is the ${job} job of hyperconfig, started by ${job}.timer on
        ${config.infraSpace.member}; nobody is watching. Follow the ${job}
        skill from step 1 to the report, under Dave's policy in it.
        End with the skill's ${tag} line.
      '';
      maxTurns = 3000;
    };

  jobs = [
    (mkJob {
      job = "cve-watch";
      description = "Nightly CVE watch of the fleet by the infra agent";
      # After the 01:30 bump (which it waits for), before the weekly jobs'
      # 03:30.
      calendar = "*-*-* 02:30:00 Asia/Bangkok";
      tag = "CVE-WATCH";
      okVerdicts = [
        "quiet"
        "acted"
        "reported"
      ];
      quietVerdicts = [ "quiet" ];
      timeout = "12h";
    })
    (mkJob {
      job = "hygiene-report";
      description = "Weekly hygiene report of hyperconfig by the infra agent";
      # Saturday 03:30 at Dave's (Dave's weekly table: Sat hygiene).
      calendar = "Sat *-*-* 03:30:00 Asia/Bangkok";
      tag = "HYGIENE";
      okVerdicts = [
        "clean"
        "fixed"
        "reported"
      ];
      timeout = "10h";
    })
    (mkJob {
      job = "security-audit";
      description = "Weekly security audit of the fleet by the infra agent";
      # Sunday 03:30 at Dave's, the day after the hygiene run.
      calendar = "Sun *-*-* 03:30:00 Asia/Bangkok";
      tag = "SECURITY-AUDIT";
      okVerdicts = [
        "all-clear"
        "fixed"
        "reported"
      ];
      timeout = "12h";
    })
  ];
in
{
  options.infraSpace.securityJobs.skills = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    readOnly = true;
    internal = true;
    description = "The security jobs' SKILL.md texts (./hermes.nix makes skills of them).";
    default = lib.genAttrs [
      "cve-watch"
      "hygiene-report"
      "security-audit"
    ] skillText;
  };

  config = lib.mkMerge (
    [
      {
        environment.systemPackages = [
          (workspace "cve-watch")
          (workspace "hygiene-report")
          (workspace "security-audit")
          guard
          protectedCheck
          deploy
          collect
          feeds
          jobNix
          pkgs.vulnix
        ];
        # The registry's `decision` CLI comes from ./decisions.nix (it owns
        # /var/lib/infra-space/decisions; never a tmpfiles entry here).
      }
    ]
    ++ jobs
  );
}
