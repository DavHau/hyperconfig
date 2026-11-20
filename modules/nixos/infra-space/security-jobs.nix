/*
  The infra-space security jobs run as the unprivileged guest `infra-jobs`,
  never as the fleet-admin `infra`. ./hermes.nix gives that account its own
  locked hermes agent with only these jobs' skills and the hyperconfig map.
  It has no GitHub/fleet/age credential and no usable clan wrapper. Its clone
  is the public read-only https repository, retried like ./guest.nix's.

  Unavoidably privileged operations have fixed sudo-to-infra entry points
  (no new root daemon): sec-job-push, sec-job-deploy, sec-collect and
  sec-job-decision. Every run/job/machine/commit argument is validated;
  output paths are derived below fixed roots. Push fetches a bundle from
  /run/agent-jobs/spool into a fresh infra-owned clone, guards exactly the
  requested commit with deployed main's /run/current-system guard, then
  fast-forward pushes exactly that id. The job working copy is irrelevant.

  The three jobs use ./agent-job.nix as infra-jobs. They and the bump share
  root-created, group-accessible locks under /run/agent-jobs. Deploy and
  collector output is group-readable below /var/lib/infra-space/security-jobs.
  Decisions alone are proxied to infra's `decision` CLI (./decisions.nix).
*/
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  user = "infra-jobs";
  home = "/home/${user}";
  checkout = "${home}/hyperconfig";
  infraHome = "/home/infra";
  infraCheckout = "${infraHome}/hyperconfig";
  dir = ./security-jobs;
  bumpLock = "/run/agent-jobs/nixpkgs-bump.lock";
  sharedLock = "/run/agent-jobs/security.lock";
  spool = "/run/agent-jobs/spool";
  outputRoot = "/var/lib/infra-space/security-jobs";
  sharedGroup = "agent-jobs";
  jobNames = [
    "cve-watch"
    "hygiene-report"
    "security-audit"
  ];

  # The deployable fleet, explicit (the installer is no running system).
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

  inputAncestry = pkgs.writeShellApplication {
    name = "sec-job-input-ancestry";
    runtimeInputs = [ pkgs.coreutils pkgs.git pkgs.jq ];
    # no local test origins in production
    text = builtins.replaceStrings [ "@testRoot@" ] [ "\"\"" ] (
      builtins.readFile ./security-jobs/input-ancestry.sh
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
      inputAncestry
    ];
    text = builtins.readFile ./security-jobs/guard.sh;
  };

  push = pkgs.writeShellApplication {
    name = "sec-job-push";
    runtimeInputs = [ pkgs.coreutils pkgs.git ];
    text = builtins.replaceStrings
      [ "@jobs@" "@spool@" "@origin@" "@scratchRoot@" "@guard@" ]
      [
        (lib.concatStringsSep " " jobNames)
        spool
        "git@github.com:DavHau/hyperconfig.git"
        "/var/lib/infra-space/sec-job-push"
        "/run/current-system/sw/bin/sec-job-guard"
      ]
      (builtins.readFile ./security-jobs/push.sh);
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
        [ "@machines@" "@repo@" "@maxJobs@" "@cores@" "@jobNix@" "@runRoot@" ]
        [
          machinesStr
          infraCheckout
          (toString maxJobs)
          (toString cores)
          (lib.getExe' jobNix "sec-job-nix")
          "${outputRoot}/deploy"
        ]
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
    text = ''
      NIX=${lib.getExe' jobNix "sec-job-nix"}
    '' + builtins.replaceStrings [ "@machines@" "@runRoot@" "@repo@" ] [
      machinesStr
      "${outputRoot}/collect"
      infraCheckout
    ] (builtins.readFile ./security-jobs/collect.sh);
  };

  # The registry for the jobs, as infra: `--by <job>` first, then only
  # the verbs the skills use, and none of the options that read a file
  # (as infra, past /home/infra's 0700) or change others' entries
  # (answer, update, close, notice --sent, ...: Dave's and sessions').
  decisionProxy = pkgs.writeShellScriptBin "sec-job-decision" ''
    set -euo pipefail
    fail() { echo "sec-job-decision: $*" >&2; exit 2; }
    [ "$#" -ge 3 ] && [ "$1" = --by ] ||
      fail "usage: sec-job-decision --by ${lib.concatStringsSep "|" jobNames} add|decided|work|notice|list|show [ARGS...]"
    by=$2
    verb=$3
    shift 3
    case " ${lib.concatStringsSep " " jobNames} " in *" $by "*) ;; *) fail "unknown job: $by" ;; esac
    case "$verb" in
      add | decided | work | notice | list | show) ;;
      *) fail "not for a security job: $verb" ;;
    esac
    # argparse also takes any unique prefix of an option (--js = --json):
    # refuse every spelling of the ones that read a file or drop notices
    for arg in "$@"; do
      [ "$arg" != -- ] || break
      case "$arg" in
        --?*)
          opt=''${arg%%=*}
          for bad in --json --file --sent --by --digest-json --recurring-json --jobs-json --options-json --bump-log-dir; do
            case "$bad" in
              "$opt"*)
                if [ "$bad" = --json ] && [ "$opt" = --json ] && { [ "$verb" = list ] || [ "$verb" = show ]; }; then
                  continue
                fi
                fail "option not for a security job: $arg" ;;
            esac
          done ;;
      esac
    done
    exec /run/current-system/sw/bin/decision --by "$by" "$verb" "$@"
  '';

  feeds = pkgs.writers.writePython3Bin "sec-cve-feeds" { doCheck = false; } (
    builtins.replaceStrings [ "@watchlist@" ] [ "${./security-jobs/watchlist.json}" ] (
      builtins.readFile ./security-jobs/cve_feeds.py
    )
  );

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
        user
        ;
      group = sharedGroup;
      fileUmask = "027";
      verdictTag = tag;
      waitFor = [ bumpLock ];
      decisionCommand = "/run/wrappers/bin/sudo -n -u infra ${decisionProxy}/bin/sec-job-decision";
      # after the nightly bump and the fleet bump (03:30, as the weekly
      # jobs): one heavy build at a time
      after = [
        "nixpkgs-bump.service"
        "fleet-bump.service"
      ];
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
      description = "Nightly CVE watch of the fleet by the unprivileged infra-jobs agent";
      calendar = "*-*-* 02:30:00 Asia/Bangkok";
      tag = "CVE-WATCH";
      okVerdicts = [ "quiet" "acted" "reported" ];
      quietVerdicts = [ "quiet" ];
      timeout = "12h";
    })
    (mkJob {
      job = "hygiene-report";
      description = "Weekly hygiene report of hyperconfig by the unprivileged infra-jobs agent";
      calendar = "Sat *-*-* 03:30:00 Asia/Bangkok";
      tag = "HYGIENE";
      okVerdicts = [ "clean" "fixed" "reported" ];
      timeout = "10h";
    })
    (mkJob {
      job = "security-audit";
      description = "Weekly security audit of the fleet by the unprivileged infra-jobs agent";
      calendar = "Sun *-*-* 03:30:00 Asia/Bangkok";
      tag = "SECURITY-AUDIT";
      okVerdicts = [ "all-clear" "fixed" "reported" ];
      timeout = "12h";
    })
  ];

  clone = pkgs.writeShellScript "infra-space-clone-infra-jobs" ''
    set -eu
    tmp=$(mktemp -d ${home}/.hyperconfig-clone.XXXXXX)
    trap 'rm -rf "$tmp"' EXIT
    if ! git clone --quiet --branch main https://github.com/DavHau/hyperconfig.git "$tmp/hyperconfig"; then
      echo "cloning the public hyperconfig failed; trying again in 15 min" >&2
      exit 0
    fi
    (cd "$tmp/hyperconfig" && jj git init --colocate)
    mv "$tmp/hyperconfig" ${checkout}
  '';
in
{
  options.infraSpace.securityJobs.skills = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    readOnly = true;
    internal = true;
    description = "The security jobs' SKILL.md texts (./hermes.nix makes skills of them).";
    default = lib.genAttrs jobNames skillText;
  };

  config = lib.mkMerge ([
    {
      users.groups = {
        ${sharedGroup} = { };
        ${user}.gid = 1223;
      };
      users.users.infra.extraGroups = [ sharedGroup ];
      users.users.${user} = {
        isNormalUser = true;
        uid = 1223;
        group = user;
        extraGroups = [ sharedGroup ];
        home = home;
        createHome = true;
        description = "Unprivileged infra-space maintenance jobs";
      };

      systemd.tmpfiles.rules = [
        "d ${home} 2750 ${user} ${sharedGroup} -"
        "d /run/agent-jobs 0770 root ${sharedGroup} -"
        "f ${bumpLock} 0660 root ${sharedGroup} -"
        "f ${sharedLock} 0660 root ${sharedGroup} -"
        "d ${spool} 2770 root ${sharedGroup} -"
        # setgid: the run directories infra makes below inherit the
        # group, so infra-jobs can read what its sudo calls produced
        "d ${outputRoot} 2750 infra ${sharedGroup} -"
        "d ${outputRoot}/deploy 2750 infra ${sharedGroup} -"
        "d ${outputRoot}/collect 2750 infra ${sharedGroup} -"
        "d /var/lib/infra-space/sec-job-push 0700 infra infra -"
      ];

      environment.systemPackages = [
        (workspace "cve-watch")
        (workspace "hygiene-report")
        (workspace "security-audit")
        guard
        inputAncestry
        protectedCheck
        push
        deploy
        collect
        decisionProxy
        feeds
        jobNix
        pkgs.vulnix
      ];

      security.sudo.extraRules = [{
        users = [ user ];
        runAs = "infra:infra";
        # Each by its store path and by the system profile's (root-owned)
        # path: sudo matches the name the caller resolved through PATH
        # (/run/current-system/sw/bin/...), not the symlink's target.
        commands = lib.concatMap
          (bin: map (command: { inherit command; options = [ "NOPASSWD" ]; }) [
            bin
            "/run/current-system/sw/bin/${baseNameOf bin}"
          ])
          [
            "${push}/bin/sec-job-push"
            "${deploy}/bin/sec-job-deploy"
            "${collect}/bin/sec-collect"
            "${decisionProxy}/bin/sec-job-decision"
          ];
      }];

      systemd.services.infra-space-clone-infra-jobs = {
        description = "Clone public hyperconfig for the unprivileged security jobs";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        unitConfig.ConditionPathExists = "!${checkout}";
        path = [ pkgs.coreutils pkgs.git pkgs.jujutsu ];
        environment = {
          JJ_USER = "infra-jobs (${config.infraSpace.member})";
          JJ_EMAIL = "infra-jobs@${config.infraSpace.member}.d";
        };
        serviceConfig = {
          Type = "oneshot";
          User = user;
          Group = user;
          WorkingDirectory = home;
          ExecStart = clone;
        };
      };
      systemd.timers.infra-space-clone-infra-jobs = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15min";
          OnUnitInactiveSec = "15min";
        };
      };
    }
  ] ++ jobs);
}
