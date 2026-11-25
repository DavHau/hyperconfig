# dave-hermes works on nmm (the asof project's swarm, asof-agents slot)
# alongside Dave's afk sessions there, from its hermes profile `nmm`.
# Status and the risks Dave accepted: ../../docs/dave-hermes-nmm.md.
#
#   - ssh: dave-hermes logs in as `agent` in asof-agents with its own key
#     (clan var dave-hermes-nmm-ssh, owner dave-hermes). `ssh asof-agents`
#     resolves through the ssh_config block below (address, user, key, the
#     guest's host key pinned here). The key is authorized for `agent` by
#     nmm's own flake (deployed by the swarm, not from here): until that
#     lands the login is refused.
#   - skills, only in dave-hermes' profile `nmm` (a skillDir would reach
#     all of its profiles), through hyperhermes' profileSkills: `nmm`
#     (./dave-hermes-nmm/nmm, no text from the container) is seeded once
#     and then the agent's own, like any skill it writes; `nmm-tools`
#     (./dave-hermes-nmm/nmm-tools, the `remote` CLI's recipes) is ours
#     and rewritten on every sync. hyperhermes can't declare profiles:
#     dave-hermes-nmm-profile.service, as dave-hermes, creates the profile
#     once (`hermes profile create`) and touches nothing afterwards.
#   - `remote asof-agents run|put|get|ro|pane|steer|task-status`:
#     hyperhermes' remote CLI (hyperhermes/modules/core/remotes.nix) with
#     this target; the swarm commands run ./dave-hermes-nmm/swarm-task.py
#     in the slot.
#
# Nothing here reads the container or restarts it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = "dave-hermes";
  slot = config.services.container-slots;
  # asof-agents' public v6 (container-slots: <prefix>::5107:<id hex>).
  address = "${slot.ipv6Prefix}::5107:${lib.toLower (lib.toHexString slot.slots.asof-agents.id)}";
  somAddress = "${slot.ipv6Prefix}${config.networking.publicIPv6.token}";
  key = config.clan.core.vars.generators.dave-hermes-nmm-ssh.files.key.path;
  # The guest's ed25519 host key, pinned in ../../modules/nixos/spaces/slots.nix
  # (also for Dave's desktops). If it changes, the login fails closed.
  knownHosts = pkgs.writeText "asof-agents-known-hosts" ''
    asof-agents ${(import ../../modules/nixos/spaces/slots.nix).asof-agents.hostKey}
  '';
  hermesHome = "/var/lib/hermes/${agent}/state/.hermes";
  profile = "${hermesHome}/profiles/nmm";
in
{
  clan.core.vars.generators.dave-hermes-nmm-ssh = {
    files.key = {
      secret = true;
      owner = agent;
    };
    files."key.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -q -t ed25519 -N "" -C "${agent}-nmm@som" -f "$out"/key
    '';
  };

  # `ssh asof-agents`, for dave-hermes only. From som's stable public
  # address (networking.publicIPv6), not a rotating temporary one, so nmm
  # pins the key with from=.
  programs.ssh.extraConfig = ''
    Match host asof-agents localuser ${agent}
      HostName ${address}
      User agent
      IdentityFile ${key}
      IdentitiesOnly yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${knownHosts}
      GlobalKnownHostsFile /dev/null
      HostKeyAlias asof-agents
      BindAddress ${somAddress}
      ForwardAgent no
      ForwardX11 no
  '';

  services.hyperhermes.agents.${agent} = {
    profileSkills.nmm = {
      nmm.source = ./dave-hermes-nmm/nmm;
      nmm-tools = {
        source = ./dave-hermes-nmm/nmm-tools;
        managed = true;
      };
    };
    remotes.asof-agents = {
      description = "the nmm repo and its swarm (user agent)";
      cwd = "nmm";
      # The slot's unsnapshotted, never backed up scratch dataset.
      scratch = "/scratch/hermes";
      commands = {
        ro = {
          # The slot's `ssh asof` reaches the project's read-only account,
          # a forced command that shlex-splits the one string it gets.
          kind = "joined";
          prefix = [
            "ssh"
            "-o"
            "BatchMode=yes"
            "asof"
          ];
          timeout = 310;
          usage = "[timeout N] COMMAND [ARG...]";
          help = ''
            One command of the project's read-only account, words passed
            exactly. No shell there: no pipes, ;, &&, redirections, globs.
            Post-process with `run --script` (call `ssh asof ...` inside).
            systemctl status|show|list-units|list-timers|is-active|is-failed
              [-a -l -q --no-legend --plain --value --failed -p P -t T
              --state S -n N -o O] [UNIT...]
            journalctl [-u UNIT -t ID -g PATTERN -n N -p PRIO -o FMT -S SINCE
              -U UNTIL -r -a -q -b -k --utc --output-fields F]  (no positionals)
            df [-h -H -P -k -T -i -l -a --total --output=F] [/ABS/PATH...]
              (one flag per word: -h -T, never -hT)
            asof status
            asof query --dataset D --as-of T [--from --to --columns
              --visibility --limit --format] [--root /vault/parquet]
              (no --url, --token, --out, --policy, no positionals; without
              --root it asks the service, the only mode taking --as-of now)
            cat|head|tail|ls /ABS/PATH... under the account's read prefixes
              (/var/lib/asof* and the one its refusal names) only, no
              secrets; head/tail -n N (never -20);
              ls -l|-a|-la
            each optionally after `timeout N` (N <= 300). A refusal prints
            the account's allowlist: read it, don't retry blind.'';
        };
        pane = {
          kind = "script";
          prefix = [ "python3" ];
          script = ./dave-hermes-nmm/swarm-task.py;
          args = [ "pane" ];
          timeout = 60;
          usage = "TASK [LINES]";
          help = "The swarm's herdr panes of TASK (session `swarm`, cwd ~/workspaces/TASK); with LINES, the live pane's last lines.";
        };
        steer = {
          kind = "script";
          prefix = [ "python3" ];
          script = ./dave-hermes-nmm/swarm-task.py;
          args = [ "steer" ];
          timeout = 60;
          usage = "TASK MESSAGE...";
          help = "Prompt the running agent of TASK with MESSAGE (herdr agent prompt). For a running task; `swarm task edit` only works while it is ready.";
        };
        task-status = {
          kind = "script";
          prefix = [ "python3" ];
          script = ./dave-hermes-nmm/swarm-task.py;
          args = [ "status" ];
          timeout = 60;
          usage = "TASK...";
          help = "One line per task: id, status, wait_for, updated, live pane, title.";
        };
      };
    };
  };

  systemd.services.dave-hermes-nmm-profile = {
    description = "dave-hermes' hermes profile nmm";
    wantedBy = [ "multi-user.target" ];
    # The `hermes` shim refuses to run while the agent's gateway is down.
    wants = [ "hermes-agent-${agent}.service" ];
    after = [ "hermes-agent-${agent}.service" ];
    path = [ pkgs.coreutils ];
    script = ''
      if [ ! -e ${profile} ]; then
        # As Dave would make it: hermes' own layout and the agent's model.
        /run/current-system/sw/bin/hermes profile create nmm --no-alias \
          --description "Works on Dave's nmm/asof project over ssh asof-agents."
        printf '\n%s\n' "This profile works on Dave's nmm (asof) project in the asof-agents container over ssh; load the nmm skill first." >> ${profile}/SOUL.md
      fi
      # Its skills come with hyperhermes' profile sync (profileSkills).
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = agent;
      Group = "users";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      # Its own hermes home, and its home dir (the shim's HOME and cwd).
      ReadWritePaths = [
        hermesHome
        config.users.users.${agent}.home
      ];
      TimeoutStartSec = "2min";
    };
  };
}
