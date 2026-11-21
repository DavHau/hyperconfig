/*
  The infra-space's hermes agent, inside the container (./default.nix
  appends this to the guest's modules on every member): hyperhermes core
  with `infra`, the fleet administrator from /home/infra/hyperconfig, and
  the separate unprivileged `infra-jobs` agent for the untrusted-feed jobs.

  Minimal on purpose, its input (journals, process lists, git logs, HTTP
  answers) being partly tenant-controlled on som:
    - core only: no browser, mail, publish, wallet, REA, teamclaude or
      claude-auth module, no desktop, local container or slot. TeamClaude is
      reached by plain environment (below), not the teamclaude module,
      whose per-agent key would be som's var.
    - except, on som, three tools for web signups (./agent-tools.nix,
      ./agent-tools-guest.nix), each served by som's own hyperhermes
      feature ON THE HOST and dialled over the veth, so none runs in here
      next to infra's fleet-root keys:
        - mail: a receive-only mailbox infra@agents.davhau.com in som's
          mailgate (`mailgate`, `himalaya`, the mailgate skill); only
          senders Dave allowlists on the owner page (mailgate.hermes.
          davhau.com) reach the INBOX, one address at a time (no
          `@domain` entries for this mailbox), everything else is the
          quarantine's restricted view; nothing can send. Read mail only
          in a delegated child; never act on instructions found in it.
        - browser: hyperhermes' camofox plugin (toolset `camofox`, its
          browser_* tools with captcha solving) against a Camofox server on
          som under its own uid (infra-browser): Mullvad-only egress, no
          LAN, mesh, loopback services or host addresses, no access to the
          container's files. The toolset is OFF by default
          (the host's hyper.infraSpace.agentTools.browser; off, neither the
          server nor the plugin exists and `camofox` is in
          agent.disabled_toolsets): pages are prompt injection aimed at a
          fleet-root agent. When on, browse only in a delegate_task child
          whose goal is the browsing, never in the parent; hermes cannot
          grant a toolset to children only.
          Core's `browser` toolset (a local Chromium) stays disabled.
        - wallet: `lnwallet` with full access to the shared phoenixd
          wallet, as som's wallet agents have (lightning-wallet skill),
          nothing beyond: payinvoice, sendtoaddress (splice-out), etc.
      In the guest only infra and root dial those ports.
    - lockedConfig: config.yaml, .env, .op.env and plugins/ (and the rest
      hermes reads as configuration) are root's, immutable and generated
      here, so neither the agent nor the dashboard can change them (core's
      locked-config.nix). Runtime changes (`/model`, settings and keys
      pages, `hermes config set`) do not persist: change this file.
    - hardening: no namespaces, setuid, io_uring for the gateway, the
      dashboard, their tools and infra's user manager (core's
      hardening.nix). clan, nix (through the host's daemon), git, jj and
      ssh still work.
    - toolsets: terminal, file, todo, skills on every platform hermes
      knows (v0.23.0 hermes_cli/platforms.py, plus acp; the dashboard's
      chat runs `hermes --tui`, which resolves as `cli`), and
      agent.disabled_toolsets as the hard cap on every other toolset
      (hermes_cli/tools_config.py _get_platform_tools applies it last, on
      every surface, cron included). Only toolsets whose tools none of the
      four share: the cap works per tool (_prune_toolsets_stripped_by_
      disabled), so a composite like `debugging` would take terminal and
      file with it. Checkpoints off.
    - skills: the infra skill (./hermes-skill), the nightly bump's
      (./nixpkgs-bump), the security jobs' (./security-jobs) and the repo's own map of hyperconfig
      (../../../skills/hyperconfig-map, for the agent and its subagents),
      and of the bundled ones only systematic-debugging
      and codebase-inspection: the rest of what the package ships is
      disabled, read from its source at eval time (hermes has no
      allowlist), but for hermes' essential hermes-agent,
      which stays on (under OAuth the prompt calls it claude-code; the
      bundled claude-code skill is another one, disabled).
    - the nightly nixpkgs bump (./nixpkgs-bump.nix): a timer that starts
      the agent with ./nixpkgs-bump/SKILL.md; here only, so on som only.
      Beside it the deterministic bump (./fleet-bump), branch-only for
      now: it builds .#fleetJobs and pushes auto/nixpkgs, never main.
    - the decision registry (./decisions.nix): `decision`, the 08:00
      curation run, the 09:00 brief and the /decisions skill; som only.
      The security jobs (./security-jobs.nix: nightly CVE watch, weekly
      hygiene report and security audit) the same way.

  Inference: Claude Opus 5.5 through TeamClaude (the model) with the
  shared client key (../provider-keys.nix, booked as `hyperconfig`),
  and p0's Qwen as a provider (machines/som/hermes-inference.nix) for
  titles and as the vision describer for text-only models. Both keys arrive as the host's credentials
  `p0-api-key` and `teamclaude-api-key`, the dashboard's OIDC client secret
  (som only) as `dashboard-oidc-secret`; hermes-locked-infra takes them
  from the guest's system credentials into the root-owned .env.

  Dashboard: core's, on the guest's loopback as always; with
  infraSpace.hermes.dashboard.enable (som, ./dashboard.nix) it runs gated
  by hermes' own OIDC login (the settings hyperhermes' dashboards module
  would set, which cannot be used here: it fronts agents on its own host
  with its own nginx) and a socket proxy on the guest's veth address lets
  the host's nginx in. The guest firewall admits only the host there
  (./guest.nix), the host drops forwarded connections into the veth
  (./default.nix). The proxy dials core's root-held dashboard port as its
  own uid, admitted next to infra and root in core's owner gate.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.infraSpace.hermes;
  user = "infra";
  jobsUser = "infra-jobs";
  hlib = inputs.hyperhermes.lib;
  # System credentials the host passes in (nspawn --load-credential), read
  # by hermes-locked-infra (root) through LoadCredential.
  credential = name: "/run/credentials/@system/${name}";

  # delegation: subagents (delegate_task). Children inherit these toolsets
  # and the disabled_toolsets cap below (tools/delegate_tool.py
  # _resolve_child_toolsets), so they get nothing the agent lacks.
  allowedToolsets = [
    "terminal"
    "file"
    "todo"
    "skills"
    "delegation"
  ]
  ++ cfg.extraToolsets;
  # Every platform key of hermes v0.23.0's registry, and acp (its adapter
  # resolves `acp`, which has no registry entry).
  platforms = [
    "cli"
    "telegram"
    "discord"
    "slack"
    "whatsapp"
    "whatsapp_cloud"
    "signal"
    "bluebubbles"
    "email"
    "mattermost"
    "matrix"
    "dingtalk"
    "feishu"
    "wecom"
    "wecom_callback"
    "weixin"
    "qqbot"
    "yuanbao"
    "webhook"
    "api_server"
    "cron"
    "acp"
  ];
  # Every v0.23.0 toolset that shares no tool with the four above (toolsets.py
  # TOOLSETS; `safe` and `hermes-webhook` are composites of such), and the
  # bundled a2a plugin's.
  disabledToolsets = [
    "web"
    "search"
    "x_search"
    "vision"
    "video"
    "image_gen"
    "video_gen"
    "computer_use"
    "browser"
    "cronjob"
    "tts"
    "memory"
    "context_engine"
    "session_search"
    "connections"
    "project"
    "bot_room"
    "desktop_ui"
    "onboarding"
    "catalog"
    "clarify"
    "code_execution"
    "kanban"
    "discord"
    "discord_admin"
    "yuanbao"
    "feishu_doc"
    "feishu_drive"
    "safe"
    "hermes-webhook"
    "a2a"
  ];
  # The skills that stay on: ours (nixSkills, no bundled one has their
  # names) and two bundled ones. hermes has no allowlist, so every other
  # skill the package ships is disabled, a hermes update's new ones
  # included.
  allowedSkills = map (s: s.passthru.skillName) (nixSkills ++ cfg.extraSkills) ++ [
    "systematic-debugging"
    "codebase-inspection"
  ];
  # The bundled skills of the package in use, by the name hermes disables
  # them by: the frontmatter `name:`, else the directory's
  # (tools/skills_tool.py). skills/<category>/<skill>/SKILL.md of its
  # source, upstream's passthru.agentBuilderSrc.origSrc: a flake input,
  # so read at eval time without import-from-derivation (the built
  # package's share/hermes-agent/skills would be IFD).
  bundledSkills =
    let
      root = config.services.hyperhermes.package.passthru.agentBuilderSrc.origSrc + "/skills";
      dirs = path: lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir path));
      nameOf =
        dir:
        let
          # the lines between the opening `---` and the next
          text = lib.replaceStrings [ "\r" ] [ "" ] (builtins.readFile (dir + "/SKILL.md"));
          frontmatter = lib.optionals (lib.hasPrefix "---\n" text) (
            lib.splitString "\n" (lib.head (lib.splitString "\n---" (lib.removePrefix "---\n" text)))
          );
          names = lib.concatMap (
            l:
            let
              m = builtins.match "name:[[:space:]]*[\"']?([^\"']*[^\"'[:space:]])[\"']?[[:space:]]*" l;
            in
            lib.optional (m != null) (lib.head m)
          ) frontmatter;
        in
        if names != [ ] then lib.head names else baseNameOf dir;
    in
    lib.concatMap (
      category:
      map nameOf (
        lib.filter (dir: builtins.pathExists (dir + "/SKILL.md")) (
          map (skill: root + "/${category}/${skill}") (dirs (root + "/${category}"))
        )
      )
    ) (dirs root);
  # hermes' ESSENTIAL_SKILLS (agent/skill_utils.py): the system prompt
  # tells the agent to skill_view it (agent/prompt_builder.py), under OAuth
  # as claude-code (the anthropic adapter's renaming, agent/
  # anthropic_adapter.py). Listed even when disabled
  # (get_disabled_skill_names drops it), but skill_view checks the raw
  # skills.disabled and would refuse it, so it stays off the list.
  essentialSkills = [ "hermes-agent" ];
  # Set host-wide, where it concatenates with core's `maps` (web fetching);
  # an agent's own list would replace that (lib.recursiveUpdate, core's
  # agent-config.nix).
  disabledSkills = lib.subtractLists (allowedSkills ++ essentialSkills) bundledSkills;

  skill = hlib.mkAgentSkill pkgs {
    name = "infra-space";
    src = pkgs.writeTextDir "SKILL.md" (
      lib.replaceStrings
        [ "@MEMBER@" "@OTHERS@" ]
        [
          config.infraSpace.member
          (lib.concatMapStringsSep ", " (m: "`ssh infra-space-${m}`") (
            lib.remove config.infraSpace.member (lib.attrNames config.infraSpace.members)
          ))
        ]
        (builtins.readFile ./hermes-skill/SKILL.md)
    );
  };

  bumpSkill = hlib.mkAgentSkill pkgs {
    name = "nixpkgs-bump";
    src = pkgs.writeTextDir "SKILL.md" (
      lib.replaceStrings [ "@MEMBER@" ] [ config.infraSpace.member ] (
        builtins.readFile ./nixpkgs-bump/SKILL.md
      )
    );
  };

  # The decision registry (./decisions.nix): /decisions for Dave's
  # sessions, decisions-curate for the 08:00 run.
  decisionsSkill = hlib.mkAgentSkill pkgs {
    name = "decisions";
    src = pkgs.writeTextDir "SKILL.md" (builtins.readFile ./decisions/SKILL.md);
  };
  curateSkill = hlib.mkAgentSkill pkgs {
    name = "decisions-curate";
    src = pkgs.writeTextDir "SKILL.md" (builtins.readFile ./decisions/curate/SKILL.md);
  };

  # The security jobs' skills (./security-jobs.nix: policy and machine
  # list spliced into each SKILL.md).
  secSkills = lib.mapAttrsToList (
    name: text:
    hlib.mkAgentSkill pkgs {
      inherit name;
      src = pkgs.writeTextDir "SKILL.md" text;
    }
  ) config.infraSpace.securityJobs.skills;

  # Where things live in hyperconfig: SKILL.md, hand-written area
  # references and the generated map (../../flake-parts/repo-map.nix keeps
  # it fresh). Only the skill's directory goes into the store.
  mapSkill = hlib.mkAgentSkill pkgs {
    name = "hyperconfig-map";
    src = lib.fileset.toSource {
      root = ../../../skills/hyperconfig-map;
      fileset = ../../../skills/hyperconfig-map;
    };
  };

  # The skill roots built here: the agent's skills.external_dirs.
  nixSkills = [
    skill
    bumpSkill
    mapSkill
    decisionsSkill
    curateSkill
  ]
  ++ secSkills;

  dashboardPort = hlib.dashboardPortFor user;
  proxyUser = "infra-space-dashboard";
in
{
  imports = [
    inputs.hyperhermes.nixosModules.core
    ./nixpkgs-bump.nix
    ./fleet-bump
    ./decisions.nix
    ./security-jobs.nix
  ];

  # For ./test.nix, which checks hermes' own view against them.
  options.infraSpace.hermes.skills = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    readOnly = true;
    internal = true;
    default = {
      allowed = allowedSkills;
      essential = essentialSkills;
      bundled = bundledSkills;
      nix = map (s: s.passthru.skillName) (nixSkills ++ cfg.extraSkills);
    };
  };

  # For ./agent-tools-guest.nix.
  options.infraSpace.hermes.extraSkills = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = "More skill packages (hyperhermes.lib.mkAgentSkill) for the agent, allowed like nixSkills.";
  };
  options.infraSpace.agentJobs = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          logDir = lib.mkOption { type = lib.types.str; };
          verdictTag = lib.mkOption { type = lib.types.str; };
          okVerdicts = lib.mkOption { type = lib.types.listOf lib.types.str; };
        };
      }
    );
    default = { };
    internal = true;
    description = "The agent's unattended jobs (./agent-job.nix registers each): where their logs are and which last line is a good run; the morning brief (./decisions.nix) reports a failed one.";
  };
  options.infraSpace.hermes.extraToolsets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "More toolsets for the agent on EVERY platform (cli, the dashboard, every gateway platform, acp), and so for its delegate_task children, which inherit the parent's toolsets.";
  };

  options.infraSpace.hermes.dashboard = {
    enable = lib.mkEnableOption "the agent's dashboard for the host's nginx, behind hermes' OIDC login";
    url = lib.mkOption {
      type = lib.types.str;
      description = "The dashboard's public origin (hermes' dashboard.public_url: the only Host and WS Origin it accepts).";
    };
    issuer = lib.mkOption {
      type = lib.types.str;
      description = "OIDC issuer (https).";
    };
    clientId = lib.mkOption {
      type = lib.types.str;
      description = "The confidential OIDC client; its secret is the credential `dashboard-oidc-secret`.";
    };
    allowedGroup = lib.mkOption {
      type = lib.types.str;
      description = "The one group whose members get a session.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      description = "The guest's veth address the host's nginx dials.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9119;
      description = "Port on listenAddress.";
    };
  };

  config = lib.mkMerge [
    {
      # branch-only (auto/nixpkgs) beside the agent's bump (./fleet-bump)
      infraSpace.fleetBump = {
        enable = true;
        waitFor = [ "nixpkgs-bump.service" ];
      };

      # The guest's root has no CAP_LINUX_IMMUTABLE in its user namespace
      # (../spaces/host.nix, privateUsers): lockedConfig's pins get their
      # flag from the host's helper (immutableHelper, ./default.nix).
      systemd.services."hermes-locked-${user}".environment.HERMES_LOCKED_IMMUTABLE_HELPER =
        "/run/space-immutable/socket";
      systemd.services."hermes-locked-${jobsUser}".environment.HERMES_LOCKED_IMMUTABLE_HELPER =
        "/run/space-immutable/socket";
      # No dashboard for the unattended account: no forward, no listener.
      systemd.services."hermes-dashboard-${jobsUser}".wantedBy = lib.mkForce [ ];
      # Its four fixed sudo-to-infra entry points are the intended privilege
      # boundary. The gateway-wide hardening otherwise rejects every setuid
      # executable; keep the rest, but let sudo perform those transitions.
      systemd.services."hermes-agent-${jobsUser}".serviceConfig = {
        NoNewPrivileges = lib.mkForce false;
        RestrictSUIDSGID = lib.mkForce false;
      };

      services.hyperhermes = {
        hardening.enable = true;
        forwards.dashboard.enabledFor = name: name != jobsUser;

        # p0, as on som (machines/som/hermes-inference.nix): the provider
        # entry, Qwen with thinking as the model, titles from it too.
        settings.providers.p0 = {
          base_url = "https://inference.p0.contact/v1";
          key_env = "P0_API_KEY";
          default_model = "qwen";
          extra_body.chat_template_kwargs.enable_thinking = true;
          models = {
            qwen.supports_vision = true;
            "Qwen3.8-27B-FP8".supports_vision = true;
          };
        };
        settings.auxiliary.title_generation = {
          provider = "p0";
          model = "qwen";
        };
        # Same describer for text-only models as on som; moot while the
        # vision toolset is disabled and the model is Claude (native).
        settings.auxiliary.vision = {
          provider = "p0";
          model = "qwen";
        };
        settings.sessions.auto_prune = false;
        settings.skills.disabled = disabledSkills;
        # The model: Claude Opus 5.5 via the anthropic provider (TeamClaude,
        # below). lockedConfig writes it as config.yaml's model on every
        # start, so this is the model, not just a seed.
        initialModel = {
          provider = "anthropic";
          default = "claude-opus-5-5";
        };

        agents.${user} = {
          inherit (config.space) uid;
          lockedConfig = true;
          # TeamClaude as the Anthropic endpoint, with the fleet's shared
          # client key (hermes seeds its env:ANTHROPIC_TOKEN credential with
          # ANTHROPIC_BASE_URL, as hyperhermes' teamclaude module sets them).
          environment.ANTHROPIC_BASE_URL = "https://teamclaude.davhau.com";
          secretEnv = {
            P0_API_KEY = credential "p0-api-key";
            ANTHROPIC_TOKEN = credential "teamclaude-api-key";
            # OpenRouter for headless runs on other models (hermes chat --provider openrouter)
            OPENROUTER_API_KEY = credential "openrouter-api-key";
          };
          skillDirs = map (s: "${s}/share/skills") (nixSkills ++ cfg.extraSkills);
          settings = {
            terminal.timeout = 3600;
            platform_toolsets = lib.genAttrs platforms (_: allowedToolsets);
            # camofox: hyperhermes' browser plugin (./agent-tools-guest.nix),
            # capped too unless it is turned on: hermes enables a plugin's
            # toolset by default wherever the plugin is installed.
            agent.disabled_toolsets = lib.subtractLists cfg.extraToolsets (disabledToolsets ++ [ "camofox" ]);
            checkpoints.enabled = false;
            # Background subagents of all sessions share this cap (default 10,
            # which the infra session's fan-outs hit); as on som's agents.
            delegation.max_concurrent_children = 20;
          };
        };

        # Untrusted-feed work is a separate account and agent. TeamClaude is
        # inference only; no P0/OpenRouter key, fleet credential or dashboard.
        agents.${jobsUser} = {
          uid = 1223;
          lockedConfig = true;
          environment.ANTHROPIC_BASE_URL = "https://teamclaude.davhau.com";
          secretEnv.ANTHROPIC_TOKEN = credential "teamclaude-api-key";
          skillDirs = map (s: "${s}/share/skills") (secSkills ++ [ mapSkill ]);
          settings = {
            terminal.timeout = 3600;
            platform_toolsets = lib.genAttrs platforms (_: [ "terminal" "file" "todo" "delegation" ]);
            agent.disabled_toolsets = disabledToolsets ++ [ "skills" "camofox" ];
            checkpoints.enabled = false;
            delegation.max_concurrent_children = 4;
          };
        };
      };
    }

    (lib.mkIf cfg.dashboard.enable {
      # What hyperhermes' dashboards module sets per agent: the gate, its
      # provider and the pinned-off basic/nous providers (its header says
      # why); the client secret as a credential. dashboardDropEnv is moot:
      # the .env is root's.
      services.hyperhermes.agents.${user} = {
        environment = {
          HERMES_DASHBOARD_PUBLIC_URL = cfg.dashboard.url;
          HERMES_DASHBOARD_OIDC_ISSUER = cfg.dashboard.issuer;
          HERMES_DASHBOARD_OIDC_CLIENT_ID = cfg.dashboard.clientId;
          HERMES_DASHBOARD_OIDC_SCOPES = "openid profile email groups offline_access";
          HERMES_DASHBOARD_OIDC_ALLOWED_GROUPS = cfg.dashboard.allowedGroup;
        };
        secretEnv.HERMES_DASHBOARD_OIDC_CLIENT_SECRET = credential "dashboard-oidc-secret";
      };
      services.hyperhermes.settings.dashboard = {
        oauth.client_id = "";
        basic_auth = {
          username = "";
          password_hash = "";
          password = "";
        };
      };

      users.users.${proxyUser} = {
        isSystemUser = true;
        group = proxyUser;
      };
      users.groups.${proxyUser} = { };
      systemd.sockets.infra-space-dashboard = {
        description = "infra-space dashboard for the host's nginx";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${cfg.dashboard.listenAddress}:${toString cfg.dashboard.port}" ];
        socketConfig.FreeBind = true;
      };
      systemd.services.infra-space-dashboard = {
        description = "Forward the host's nginx to the infra-space dashboard";
        serviceConfig = {
          ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString dashboardPort}";
          User = proxyUser;
          Group = proxyUser;
          PrivateTmp = true;
        };
      };
      # core's owner gate on the root-held port admits infra and root; the
      # proxy too, ahead of its REJECT (as the dashboards module does for
      # nginx).
      systemd.services.hermes-firewall.script = lib.mkAfter ''
        iptables -w -I ${hlib.chain} 1 -p tcp --dport ${toString dashboardPort} -m owner --uid-owner ${proxyUser} -j RETURN
      '';
    })
  ];
}
