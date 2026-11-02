# The nixpkgs bump of the fleet flake (hyper.nixpkgsBump), nightly and on
# its agent's request: ./nixpkgs-bump.sh updates nixpkgs on upstream's
# branch, evaluates every machine and builds those of this host's system,
# hands a failure to an agent (optional, `agent`) and checks and takes its
# commits back, and delivers the result as a branch of a local bare repo.
# Nothing is pushed or deployed; from another machine:
#   git fetch root@<host>:/var/lib/nixpkgs-bump/hyperconfig.git nixpkgs-bump
# (/etc/gitconfig lists that repo as safe.directory: its owner is not root).
#
# Who is who:
#   - nixpkgs-bump: the pipeline, an unprivileged system user with no group,
#     no secrets (it never reads /run/secrets) and no trust in nix-daemon. It
#     evaluates in pure flake mode only and never takes a flake's nixConfig.
#   - the agent's account (agent.user) runs the hand-off unit
#     nixpkgs-bump-agent: the pipeline may start exactly that unit (polkit,
#     verb start only). It is our own code, not an agent, so the job-mode
#     caveat of a polkit grant (hyperhermes' slots module) does not apply.
#   - nixpkgs-bump-share: what the agent's slot acts as on the host when it
#     writes its clone (its slot share, wired by the agent's machine). Not
#     the agent's own account: a slot steering a share operation through a
#     swapped symlink (container-slots' header) must not reach the agent's
#     host state (its .env, its keys).
#
# Directories:
#   /var/lib/nixpkgs-bump          the pipeline's (0755): the delivery repo
#                                  hyperconfig.git, the work tree, gcroots/
#   /var/lib/nixpkgs-bump/public   read-only for the slot (`publicDir`):
#                                  status.json, runs/<id>/ (each run's log and
#                                  per-machine logs), handoff/ (the bundle, the
#                                  failing logs and the prompt of a hand-off)
#   /var/lib/nixpkgs-bump-agent    the slot's (`agentDir`, nixpkgs-bump-share,
#                                  group-readable for the pipeline): the
#                                  agent's clone, and requests/, where a file
#                                  named `bump` asks for a run (`requestFile`)
#
# Requests: a path unit starts the pipeline while requests/bump exists. No
# content and no argument reaches the pipeline; starting the running unit is
# a no-op; the pipeline deletes the request when it starts and again when it
# ends, so a request made during a run (the agent's own, while the run had
# handed it a failure) is answered by that run and never starts another one.
# requests/ is the pipeline's (sticky, group-writable for the share user),
# so the pipeline may delete what the slot put there.
#
# Load: the pipeline unit runs at Nice 19, idle CPU and I/O class, with a
# memory ceiling, and evaluates the machines one after the other. Builds run
# in nix-daemon's cgroup, outside all of that; what bounds them is the
# client's max-jobs and cores, which the daemon takes from untrusted clients
# too (nix src/libstore/daemon.cc, ClientSettings::apply: maxBuildJobs and
# buildCores, unconditionally). max-jobs is a hard cap on concurrent builds
# of the run; cores is NIX_BUILD_CORES, which builders honour by convention
# (make -j), not by force. Substitutions are not limited by either.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.nixpkgsBump;
  stateDir = "/var/lib/nixpkgs-bump";
  publicDir = "${stateDir}/public";
  agentDir = "/var/lib/nixpkgs-bump-agent";
  requestDir = "${agentDir}/requests";
  requestFile = "${requestDir}/bump";
  agentUnit = "nixpkgs-bump-agent";

  pipeline = pkgs.writeShellApplication {
    name = "nixpkgs-bump";
    runtimeInputs = [
      config.nix.package
      pkgs.git
      pkgs.jq
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.util-linux
      config.systemd.package
    ];
    text = builtins.readFile ./nixpkgs-bump.sh;
  };

  machinesConfig = pkgs.writeText "nixpkgs-bump-machines.json" (
    builtins.toJSON {
      inherit (cfg) hostSystem;
      machines = lib.mapAttrs (_: m: lib.filterAttrs (_: v: v != null) m) cfg.machines;
    }
  );

  # What the agent's slot runs its work with, from the host's store (which
  # the slot shares): its bootstrap system has neither git nor flakes.
  tools = pkgs.buildEnv {
    name = "nixpkgs-bump-slot-tools";
    paths = [
      config.nix.package
      pkgs.git
      pkgs.jq
      pkgs.ripgrep
      pkgs.fd
      pkgs.gnutar
      pkgs.gzip
      pkgs.diffutils
      pkgs.less
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.which
      pkgs.file
    ];
  };

  handoff = pkgs.writeShellApplication {
    name = "nixpkgs-bump-agent";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
    ];
    text = builtins.readFile ./agent-handoff.sh;
  };
in
{
  options.hyper.nixpkgsBump = with lib; {
    enable = mkEnableOption "the nixpkgs bump of the fleet flake";
    repo = mkOption {
      type = types.str;
      default = "https://github.com/DavHau/hyperconfig.git";
      description = "Upstream repository the bump starts from.";
    };
    branch = mkOption {
      type = types.str;
      default = "master";
      description = "Upstream branch the bump starts from.";
    };
    deliverBranch = mkOption {
      type = types.str;
      default = "nixpkgs-bump";
      description = "Branch of the delivery repo a green run sets (force), plus a tag <branch>-<date>.";
    };
    failedBranch = mkOption {
      type = types.str;
      default = "nixpkgs-bump-failed";
      description = "Branch of the delivery repo a red run sets (force); a git note (refs/notes/nixpkgs-bump) names the logs.";
    };
    schedule = mkOption {
      type = types.str;
      default = "*-*-* 01:30:00";
      description = "OnCalendar= of the nightly run (Persistent: a missed night runs at the next boot).";
    };
    maxJobs = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Concurrent builds of a run (nix max-jobs; the daemon honours it per client).";
    };
    cores = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "NIX_BUILD_CORES of a run's builds (nix cores; advisory to the builders).";
    };
    rounds = mkOption {
      type = types.ints.unsigned;
      default = 3;
      description = "Hand-offs to the agent per run before the run ends red.";
    };
    keepRuns = mkOption {
      type = types.ints.positive;
      default = 14;
      description = "Runs whose logs stay in ${publicDir}/runs.";
    };
    memoryMaxGiB = mkOption {
      type = types.ints.between 3 1024;
      default = 12;
      description = "MemoryMax= of the pipeline unit in GiB (its evaluations; builds run in nix-daemon's cgroup). MemoryHigh= is 2 GiB below.";
    };
    hostSystem = mkOption {
      type = types.str;
      default = pkgs.stdenv.hostPlatform.system;
      defaultText = literalExpression "pkgs.stdenv.hostPlatform.system";
      description = "Machines of this system are built; the others only evaluate (unless `machines` says otherwise).";
    };
    machines = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            attr = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "config.system.build.images.iso";
              description = "Attribute of nixosConfigurations.<name> to evaluate or build; null: config.system.build.toplevel.";
            };
            build = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Build (true) or only evaluate (false); null: build if the machine's system is hostSystem.";
            };
          };
        }
      );
      default = { };
      description = "Per-machine exceptions; every nixosConfigurations entry is checked either way.";
    };

    agent = {
      enable = mkEnableOption "the hand-off of a failing run to an agent, and the agent's requests";
      user = mkOption {
        type = types.str;
        description = "The agent's account (a hyperhermes agent with an ssh-reachable slot).";
      };
      slotTarget = mkOption {
        type = types.str;
        example = "root@10.43.18.2";
        description = "ssh destination of the agent's slot, as the agent's account reaches it (its ssh_config gives the key).";
      };
      slotPublicDir = mkOption {
        type = types.str;
        default = "/bump/in";
        description = "Where the slot sees publicDir (read-only).";
      };
      slotAgentDir = mkOption {
        type = types.str;
        default = "/bump/out";
        description = "Where the slot sees agentDir (writable).";
      };
      requires = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Units the hand-off needs up first (the slot, the agent's gateway).";
      };
      provider = mkOption {
        type = types.str;
        default = "anthropic";
        description = "hermes provider of the hand-off session.";
      };
      model = mkOption {
        type = types.str;
        default = "claude-opus-5-5";
        description = "hermes model of the hand-off session.";
      };
      skill = mkOption {
        type = types.str;
        default = "nixpkgs-bump";
        description = "Skill preloaded into the hand-off session (the agent's machine provides it).";
      };
      maxTurns = mkOption {
        type = types.ints.positive;
        default = 300;
        description = "hermes --max-turns of a hand-off session.";
      };
      timeout = mkOption {
        type = types.ints.positive;
        default = 3 * 3600;
        description = "Seconds a hand-off may take (hermes --run-budget; the unit stops it 10 minutes later).";
      };
    };

    # Read by the agent's machine to wire the slot's shares and the skill.
    publicDir = mkOption {
      type = types.str;
      readOnly = true;
      default = publicDir;
      description = "Host directory the agent's slot reads (status, logs, hand-off).";
    };
    agentDir = mkOption {
      type = types.str;
      readOnly = true;
      default = agentDir;
      description = "Host directory the agent's slot writes (its clone, requests/).";
    };
    shareUser = mkOption {
      type = types.str;
      readOnly = true;
      default = "nixpkgs-bump-share";
      description = "Host account the agent's slot shares act as.";
    };
    tools = mkOption {
      type = types.package;
      readOnly = true;
      default = tools;
      description = "The tool closure on the slot's PATH (from the host store).";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        users.users.nixpkgs-bump = {
          isSystemUser = true;
          group = "nixpkgs-bump";
          home = stateDir;
          description = "nixpkgs bump pipeline";
        };
        users.groups.nixpkgs-bump = { };

        systemd.services.nixpkgs-bump = {
          description = "nixpkgs bump of ${cfg.repo} ${cfg.branch}";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          environment = {
            STATE_DIR = stateDir;
            PUBLIC_DIR = publicDir;
            REPO_URL = cfg.repo;
            BRANCH = cfg.branch;
            DELIVER_BRANCH = cfg.deliverBranch;
            FAILED_BRANCH = cfg.failedBranch;
            GIT_NAME = "nixpkgs-bump";
            GIT_EMAIL = "nixpkgs-bump@${config.networking.hostName}";
            MACHINES_CONFIG = "${machinesConfig}";
            MAX_JOBS = toString cfg.maxJobs;
            CORES = toString cfg.cores;
            ROUNDS = toString cfg.rounds;
            KEEP_RUNS = toString cfg.keepRuns;
          }
          // lib.optionalAttrs cfg.agent.enable {
            REQUEST_FILE = requestFile;
            AGENT_UNIT = "${agentUnit}.service";
            AGENT_REPO = "${agentDir}/hyperconfig";
            SLOT_PUBLIC_DIR = cfg.agent.slotPublicDir;
            SLOT_REPO = "${cfg.agent.slotAgentDir}/hyperconfig";
          };
          serviceConfig = {
            Type = "oneshot";
            User = "nixpkgs-bump";
            Group = "nixpkgs-bump";
            ExecStart = lib.getExe pipeline;
            StateDirectory = "nixpkgs-bump";
            StateDirectoryMode = "0755";
            UMask = "0022";
            # A run with every hand-off may take long; a hung one must not
            # hold the next night's.
            TimeoutStartSec = "20h";
            # Gentle: other work keeps the CPU, the disk and the memory.
            Nice = 19;
            CPUSchedulingPolicy = "idle";
            CPUWeight = "idle";
            IOSchedulingClass = "idle";
            IOWeight = 10;
            MemoryMax = "${toString cfg.memoryMaxGiB}G";
            MemoryHigh = "${toString (cfg.memoryMaxGiB - 2)}G";
            # No secrets, nothing outside its state.
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            # It deletes the agent's requests (the header).
            ReadWritePaths = lib.optional cfg.agent.enable "-${requestDir}";
            InaccessiblePaths = [
              "-/run/secrets"
              "-/run/secrets-for-users"
              "-/var/lib/sops-nix"
            ];
          };
        };

        systemd.timers.nixpkgs-bump = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.schedule;
            Persistent = true;
            RandomizedDelaySec = "15min";
          };
        };

        # Root (the user's other machines fetch as root@) reads a repo it
        # does not own; git refuses that unless it is listed here.
        programs.git.enable = true;
        programs.git.config.safe.directory = [ "${stateDir}/hyperconfig.git" ];
      }

      (lib.mkIf cfg.agent.enable {
        users.users.nixpkgs-bump-share = {
          isSystemUser = true;
          group = "nixpkgs-bump-share";
          description = "nixpkgs bump agent slot's identity on its share";
        };
        users.groups.nixpkgs-bump-share = { };

        # publicDir: the pipeline's, world-readable (the slot reads it as
        # the share user). agentDir: the share user's, group nixpkgs-bump
        # (setgid, so what the slot creates stays readable to the pipeline);
        # old clones age out. requests/: see the header.
        systemd.tmpfiles.rules = [
          "d ${stateDir} 0755 nixpkgs-bump nixpkgs-bump -"
          "d ${publicDir} 0755 nixpkgs-bump nixpkgs-bump -"
          "d ${agentDir} 2750 nixpkgs-bump-share nixpkgs-bump 14d"
          "d ${requestDir} 1770 nixpkgs-bump nixpkgs-bump-share -"
        ];

        systemd.paths.nixpkgs-bump-request = {
          description = "nixpkgs bump requested by its agent";
          wantedBy = [ "paths.target" ];
          pathConfig = {
            PathExists = requestFile;
            Unit = "nixpkgs-bump.service";
          };
        };

        systemd.services.${agentUnit} = {
          description = "nixpkgs bump: hand a failing run to ${cfg.agent.user}";
          wants = cfg.agent.requires;
          after = cfg.agent.requires;
          environment = {
            HANDOFF_DIR = "${publicDir}/handoff";
            SLOT_TARGET = cfg.agent.slotTarget;
            SLOT_HANDOFF_DIR = "${cfg.agent.slotPublicDir}/handoff";
            SLOT_REPO = "${cfg.agent.slotAgentDir}/hyperconfig";
            SLOT_SETUP = "${./slot-setup.sh}";
            TOOLS = "${tools}";
            NIX_MAX_JOBS = toString cfg.maxJobs;
            NIX_CORES = toString cfg.cores;
            # core's `hermes` shim: the agent's HERMES_HOME and runtime. It
            # attaches to the agent's running gateway, which runs the
            # session (and its tools, in the slot) and records it.
            HERMES = "/run/current-system/sw/bin/hermes";
            PROVIDER = cfg.agent.provider;
            MODEL = cfg.agent.model;
            MAX_TURNS = toString cfg.agent.maxTurns;
            RUN_BUDGET = toString cfg.agent.timeout;
            SKILL = cfg.agent.skill;
          };
          serviceConfig = {
            Type = "oneshot";
            User = cfg.agent.user;
            Group = "users";
            ExecStart = lib.getExe handoff;
            TimeoutStartSec = cfg.agent.timeout + 600;
            Nice = 10;
          };
        };

        # The pipeline starts the hand-off unit, and only that, only start.
        security.polkit.enable = true;
        security.polkit.extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (action.id == "org.freedesktop.systemd1.manage-units" &&
                action.lookup("unit") == "${agentUnit}.service" &&
                action.lookup("verb") == "start" &&
                subject.user == "nixpkgs-bump") {
              return polkit.Result.YES;
            }
          });
        '';
      })
    ]
  );
}
