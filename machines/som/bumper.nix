# bumper: som's nixpkgs-bump agent. The pipeline
# (../../modules/nixos/nixpkgs-bump) updates hyperconfig's nixpkgs nightly
# and on bumper's request, and hands a failing evaluation or build to it;
# the user also directs it from its dashboard ("bump hyperconfig now"). Its
# skill (./bumper-skill) is the job description.
#
# Minimal on purpose: a hyperhermes agent of its own (uid 1115,
# ../../modules/nixos/vault-ids.nix, which also keeps it off bam's /vault),
# with only what the job needs:
#   - not in ./hermes-agents-data.nix: no wallet, REA, vault-ro or account
#     on vit's GPU host, and none of that file's per-agent mappings,
#   - no published ports, no web tools (browser, search, extract, OCR), no
#     mail,
#   - Claude through som's TeamClaude, as client `bumper`. claude-auth stays
#     on (it is host-wide, ./hermes-agents.nix): TeamClaude's subscription
#     accounts need the Claude Code OAuth shape that patch gives hermes
#     (hyperhermes' teamclaude module),
#   - its dashboard, for dave (./hermes-dashboards.nix).
#
# Where its tools run: in its slot (id 18), never on som. hermes' terminal
# backend is ssh to the slot (pinned hermes v0.22.5: terminal.* reaches the
# tool as TERMINAL_* env, hermes_cli/config.py:2124-2136 and
# gateway/run.py:1997-2046; it runs the system ssh, which takes the slot's
# Match block from hyperhermes' slots module, tools/environments/ssh.py:
# 106-118). The file tools (tools/file_tools.py:313-375,
# tools/file_operations.py:229-239) and background processes
# (tools/terminal_tool_background.py:100-103) run through that backend.
# What would still run on som is switched off: execute_code (its tool calls
# come back to the host process, tools/code_execution_tool.py:660-698, and
# the slot has no python), browser, computer use, image and speech output,
# cron (a job's pre-run script is a local process, cron/scheduler_script.py:
# 327-363), delegation, web; agent.disabled_toolsets is the hard cap for
# every surface, cron included (hermes_cli/tools_config.py:643-649,
# cron/scheduler.py:414-433). Checkpoints stay off: with the ssh backend they
# would snapshot a host path of the same name (agent/tool_executor.py:
# 96-115). Left on: todo and skills, host state only.
#
# Residuals, all within bumper's own host state: the ssh backend copies
# bumper's skills and caches to the slot's ~/.hermes and writes back what
# the slot changed there (tools/environments/file_sync.py:322-500), so the
# slot can edit bumper's skills; no secret is copied (.env and auth.json are
# refused, tools/credential_files.py:65-111). Provider keys never reach the
# slot's environment (tools/environments/local_env_policy.py).
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  bump = config.hyper.nixpkgsBump;
  slotId = 18;
  slotV4 = "10.43.${toString slotId}.2";
  adminKeys = config.users.users.root.openssh.authorizedKeys.keys;

  skill = inputs.hyperhermes.lib.mkAgentSkill pkgs {
    name = "nixpkgs-bump";
    src = pkgs.writeTextDir "SKILL.md" (
      lib.replaceStrings
        [ "@ROUNDS@" "@DELIVER@" "@FAILED@" "@PUBLIC@" "@AGENT@" "@TOOLS@" "@MAXJOBS@" "@CORES@" ]
        [
          (toString bump.rounds)
          bump.deliverBranch
          bump.failedBranch
          bump.agent.slotPublicDir
          bump.agent.slotAgentDir
          "${bump.tools}"
          (toString bump.maxJobs)
          (toString bump.cores)
        ]
        (builtins.readFile ./bumper-skill/SKILL.md)
    );
  };
in
{
  imports = [ ../../modules/nixos/nixpkgs-bump ];

  services.hyperhermes.agents.bumper = {
    uid = 1115;
    description = "bumper - nixpkgs bump agent of hyperconfig";
    sshKeys = adminKeys;
    teamclaude.enable = true;
    mail.enable = false;
    publish.enable = false;
    browser.enable = false;
    slot = {
      enable = true;
      id = slotId;
      # Evaluating one NixOS machine of the fleet takes 3-5G in the
      # evaluator, which runs in the slot (its builds run in nix-daemon's
      # cgroup); one evaluation at a time, so 8G.
      memoryMax = "8G";
      cpuQuota = "200%";
    };
    # The ssh backend runs ssh and scp from the gateway's PATH
    # (tools/environments/ssh.py:31-36).
    extraPackages = [ pkgs.openssh ];
    skillDirs = [ "${skill}/share/skills" ];
    settings = {
      terminal = {
        backend = "ssh";
        ssh_host = slotV4;
        ssh_user = "root";
        ssh_port = 22;
        ssh_key = config.services.hyperhermes.agents.bumper.sshKeyFile;
        # Its share in the slot, which exists before the first hand-off
        # made the clone below it. core's default is the host workspace,
        # which the slot does not have.
        cwd = bump.agent.slotAgentDir;
        # An evaluation or build of one machine takes minutes, not the
        # default 180 s.
        timeout = 3600;
      };
      platform_toolsets.cli = [
        "terminal"
        "file"
        "todo"
        "skills"
      ];
      agent.disabled_toolsets = [
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
        "connections"
        "code_execution"
        "delegation"
        "kanban"
        "memory"
        "session_search"
        "project"
        "bot_room"
        "desktop_ui"
        "catalog"
        "discord"
        "discord_admin"
        "yuanbao"
        "feishu_doc"
        "feishu_drive"
      ];
      checkpoints.enabled = false;
    };
  };

  # Its slot reads the pipeline's status, logs and hand-offs, and writes its
  # clone and its requests, both as nixpkgs-bump-share, never as bumper
  # (the pipeline module's header says why).
  services.container-slots.slots.bumper.shares = {
    ${bump.agent.slotPublicDir} = {
      source = bump.publicDir;
      user = bump.shareUser;
    };
    ${bump.agent.slotAgentDir} = {
      source = bump.agentDir;
      user = bump.shareUser;
    };
  };
  # Up from boot, unlike the other agents' slots (off until their agent
  # starts them): bumper's terminal is the slot, so without it bumper cannot
  # even ask for a run, and it has no `slot` command to start it (that runs
  # on the host).
  services.container-slots.slots.bumper.autoStart = lib.mkForce true;
  # All agent slots together: room for bumper's 8G evaluation next to the
  # others (each 4G at most, mostly idle). som has 60G; the ARC is capped at
  # 8G (./configuration.nix).
  services.hyperhermes.slots.limits = {
    memoryHigh = "14G";
    memoryMax = "16G";
  };

  hyper.nixpkgsBump = {
    enable = true;
    # An install medium: no root file system, so no bootable toplevel.
    machines.installer.attr = "config.system.build.images.iso";
    agent = {
      enable = true;
      user = "bumper";
      slotTarget = "root@${slotV4}";
      requires = [
        "container@bumper.service"
        "hermes-agent-bumper.service"
      ];
    };
  };
  # The hand-off unit runs as bumper, a Mullvad user: it resolves through
  # the tunnel like bumper's other units.
  hyper.mullvadEgress.dns.services = lib.mkIf (lib.elem "bumper" config.hyper.mullvadEgress.users) [
    "nixpkgs-bump-agent"
  ];

  # bumper's own processes on som (gateway, dashboard, hand-off) reach the
  # internet through Mullvad, whose kill switch still lets every tunneled
  # user reach private, LAN and mesh destinations directly
  # (../../modules/nixos/mullvad-egress/egress.nix). bumper may not: it
  # reaches its slot, loopback, nginx on som's own addresses (TeamClaude:
  # teamclaude.davhau.com's AAAA is som's) and p0 (the agents' title model,
  # ./hermes-inference.nix; its address is pinned in
  # ../../modules/nixos/virtualisation.nix). Residual: every loopback
  # service of som (the dashboard bridge needs loopback); they gate by owner
  # or by their own login.
  networking.nftables.tables.bumper-egress = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${toString config.services.hyperhermes.agents.bumper.uid} jump bumper
      }
      chain bumper {
        ip daddr ${slotV4} accept
        ip daddr 127.0.0.0/8 accept
        ip6 daddr ::1 accept
        fib daddr type local tcp dport 443 accept
        ip6 daddr 2405:9800:b901:94e3::feed:da7a tcp dport 443 accept
        fib daddr type local jump refuse
        ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } jump refuse
        ip6 daddr { fc00::/7, fe80::/10, ff00::/8, 200::/7, 42::/16, ${config.services.container-slots.ipv6Prefix}::/64 } jump refuse
      }
      chain refuse {
        meta l4proto tcp reject with tcp reset
        reject with icmpx admin-prohibited
      }
    '';
  };
}
