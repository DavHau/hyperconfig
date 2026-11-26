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
#   - root in both swarm slots (Dave's call: owner cards, placing keys,
#     anything needing root): a second key (clan var
#     dave-hermes-nmm-root-ssh, owner dave-hermes, 0400, only on som, never
#     in a slot), authorized for root in asof-agents and asof with only
#     `from=` som's stable address (a full root shell, pty allowed), through
#     container-slots' `rootKeys` (a marked block of the guest's
#     /root/.ssh/authorized_keys, rewritten after each slot start and on a
#     change; no slot restart). `ssh asof-agents-root` / `ssh asof-root`
#     and `remote asof-agents-root|asof-root` (cwd /root, put/get under /root/.cache/hermes-remote). Root in asof
#     reaches that slot's own account secrets: the nmm-tools skill forbids
#     printing or moving them.
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
  rootGen = config.clan.core.vars.generators.dave-hermes-nmm-root-ssh;
  # The swarm's slots dave-hermes reaches as root (alias <slot>-root).
  rootSlots = [
    "asof-agents"
    "asof"
  ];
  slotAddress = name: "${slot.ipv6Prefix}::5107:${lib.toLower (lib.toHexString slot.slots.${name}.id)}";
  # The guests' ed25519 host keys: asof-agents' pinned in
  # ../../modules/nixos/spaces/slots.nix (also for Dave's desktops), asof's
  # in ./slot-host-keys.nix. If one changes, the login fails closed.
  hostKeyOf = {
    asof-agents = (import ../../modules/nixos/spaces/slots.nix).asof-agents.hostKey;
    inherit (import ./slot-host-keys.nix) asof;
  };
  knownHosts = pkgs.writeText "asof-agents-known-hosts" ''
    asof-agents ${hostKeyOf.asof-agents}
  '';
  rootKnownHosts = pkgs.writeText "swarm-slots-root-known-hosts" (
    lib.concatMapStrings (n: "${n} ${hostKeyOf.${n}}\n") rootSlots
  );
  rootTarget = n: {
    host = "${n}-root";
    description = "root in the ${n} slot (full shell; never print secrets)";
    cwd = ".";
    # root-only (0700 /root/.cache, on the slot's unsnapshotted scratch
    # dataset), never under the world-writable /scratch: another slot user
    # could pre-create it and steer root's writes.
    scratch = "/root/.cache/hermes-remote";
  };
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

  # Root in the swarm's slots: its own key, so it can be revoked alone. To
  # revoke, set the slots' rootKeys = [ ] and deploy FIRST (empties the
  # block in both guests); only then remove this: dropping the setting
  # (null) leaves the last block in place.
  clan.core.vars.generators.dave-hermes-nmm-root-ssh = {
    files.key = {
      secret = true;
      owner = agent;
      mode = "0400";
    };
    files."key.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -q -t ed25519 -N "" -C "${agent}-nmm-root@som" -f "$out"/key
    '';
  };
  # The root key only from som's stable address, in exactly these slots.
  assertions = [
    {
      assertion = lib.all (
        n: lib.all (l: lib.hasPrefix ''from="${somAddress}" ssh-'' l) slot.slots.${n}.rootKeys
      ) rootSlots;
      message = "dave-hermes-nmm: every root key line in ${toString rootSlots} must start with from=\"${somAddress}\"";
    }
  ];
  services.container-slots.slots = lib.genAttrs rootSlots (_: {
    rootKeys = lib.optional rootGen.files."key.pub".exists ''from="${somAddress}" ${lib.trim rootGen.files."key.pub".value}'';
  });

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
  ''
  + lib.concatMapStrings (n: ''
    Match host ${n}-root localuser ${agent}
      HostName ${slotAddress n}
      User root
      IdentityFile ${rootGen.files.key.path}
      IdentitiesOnly yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${rootKnownHosts}
      GlobalKnownHostsFile /dev/null
      HostKeyAlias ${n}
      BindAddress ${somAddress}
      ForwardAgent no
      ForwardX11 no
  '') rootSlots;

  services.hyperhermes.agents.${agent} = {
    # `remote asof-agents-root|asof-root`, cwd root's home (/root).
    remotes.asof-agents-root = rootTarget "asof-agents";
    remotes.asof-root = rootTarget "asof";
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
