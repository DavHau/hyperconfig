/*
  The infra-space's hermes agent, inside the container (./default.nix
  appends this to the guest's modules on every member): hyperhermes core
  with one agent, `infra`, the guest's one user (./guest.nix; core's
  accounts.nix merges into that account: same uid, bash, lingering), which
  manages the fleet from /home/infra/hyperconfig.

  Minimal on purpose, its input (journals, process lists, git logs, HTTP
  answers) being partly tenant-controlled on som:
    - core only: no browser, mail, publish, wallet, REA, teamclaude or
      claude-auth module, no desktop, local container or slot. TeamClaude is
      reached by plain environment (below), not the teamclaude module,
      whose per-agent key would be som's var.
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
      knows (v0.22.5 hermes_cli/platforms.py, plus acp; the dashboard's
      chat runs `hermes --tui`, which resolves as `cli`), and
      agent.disabled_toolsets as the hard cap on every other toolset
      (hermes_cli/tools_config.py _get_platform_tools applies it last, on
      every surface, cron included). Only toolsets whose tools none of the
      four share: the cap works per tool (_prune_toolsets_stripped_by_
      disabled), so a composite like `debugging` would take terminal and
      file with it. Checkpoints off.
    - bundled skills: all but a handful of engineering ones disabled
      (hermes has no allowlist), plus the infra skill (./hermes-skill).

  Inference: Claude Opus 5.5 through TeamClaude (the model) with the
  shared client key (../teamclaude-api-key.nix, booked as `hyperconfig`),
  and p0's Qwen as a provider (machines/som/hermes-inference.nix) for
  titles. Both keys arrive as the host's credentials
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
  ];
  # Every platform key of hermes v0.22.5's registry, and acp (its adapter
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
  # Every v0.22.5 toolset that shares no tool with the four above (toolsets.py
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
  # hermes v0.22.5's bundled skills (skills/*/*/SKILL.md) but these:
  # systematic-debugging, test-driven-development, spike,
  # requesting-code-review, codebase-inspection. Gone: messaging, mail,
  # social, browsing, media, shopping, office, notes and design skills,
  # skills that drive other harnesses or delegate, the GitHub CLI (no gh
  # token here; pushes go over ssh), and hermes' own config and authoring
  # skills (its config is Nix's). Set host-wide, where it concatenates with
  # core's `maps` (web fetching); an agent's own list would replace that
  # (lib.recursiveUpdate, core's agent-config.nix).
  disabledSkills = [
    "apple-notes"
    "apple-reminders"
    "findmy"
    "imessage"
    "claude-code"
    "codex"
    "computer-use"
    "hermes-agent"
    "opencode"
    "architecture-diagram"
    "ascii-video"
    "baoyu-infographic"
    "claude-design"
    "design-md"
    "humanizer"
    "manim-video"
    "p5js"
    "popular-web-designs"
    "songwriting-and-ai-music"
    "sdlc-review"
    "email-inbox-triage"
    "himalaya"
    "gif-search"
    "songsee"
    "youtube-content"
    "obsidian"
    "airtable"
    "box"
    "document-to-action-items"
    "docx"
    "google-workspace"
    "meeting-action-items"
    "notion"
    "pdf"
    "powerpoint"
    "product-price-monitor"
    "teams-meeting-pipeline"
    "weekly-review-planning"
    "xlsx"
    "arxiv"
    "competitor-news-monitor"
    "grounded-citations"
    "llm-wiki"
    "xurl"
    "dogfood"
    "github"
    "hermes-agent-skill-authoring"
    "inspecting-hermes-desktop-dom"
    "node-inspect-debugger"
    "python-debugpy"
    "simplify-code"
    "blocked-page-recovery"
  ];

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

  dashboardPort = hlib.dashboardPortFor user;
  proxyUser = "infra-space-dashboard";
in
{
  imports = [ inputs.hyperhermes.nixosModules.core ];

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
      services.hyperhermes = {
        hardening.enable = true;

        # p0, as on som (machines/som/hermes-inference.nix): the provider
        # entry, Qwen with thinking as the model, titles from it too.
        settings.providers.p0 = {
          base_url = "https://inference.p0.contact/v1";
          key_env = "P0_API_KEY";
          default_model = "qwen";
          extra_body.chat_template_kwargs.enable_thinking = true;
        };
        settings.auxiliary.title_generation = {
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
          inherit (config.infraSpace) uid;
          lockedConfig = true;
          # TeamClaude as the Anthropic endpoint, with the fleet's shared
          # client key (hermes seeds its env:ANTHROPIC_TOKEN credential with
          # ANTHROPIC_BASE_URL, as hyperhermes' teamclaude module sets them).
          environment.ANTHROPIC_BASE_URL = "https://teamclaude.davhau.com";
          secretEnv = {
            P0_API_KEY = credential "p0-api-key";
            ANTHROPIC_TOKEN = credential "teamclaude-api-key";
          };
          skillDirs = [ "${skill}/share/skills" ];
          settings = {
            terminal.timeout = 3600;
            platform_toolsets = lib.genAttrs platforms (_: allowedToolsets);
            agent.disabled_toolsets = disabledToolsets;
            checkpoints.enabled = false;
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
