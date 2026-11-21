# dave-hermes drives nmm (the asof project's swarm, asof-agents slot)
# alongside Dave's afk sessions there.
#
#   - ssh: dave-hermes logs in as `agent` in asof-agents with its own key
#     (clan var dave-hermes-nmm-ssh, owner dave-hermes). `ssh asof-agents`
#     resolves through this file's ssh_config block (address, user, key,
#     the pinned host key); the key is authorized for `agent` only, by
#     nmm's own flake (its agents machine's configuration, deployed by the
#     swarm, not from here): until that lands the login is refused.
#   - skills: nmm-remote-skills.service exports every skill afk's sessions
#     see (trunk's .agents/skills, afk's distribution skills and rules) and
#     nmm's AGENTS.md as one skill root, refreshed every 5 minutes, which
#     dave-hermes reads as a skillDir (./dave-hermes-nmm/export.py). It
#     runs on the host, reads the container's files and git objects as
#     data, and writes only /var/lib/nmm-remote-skills.
#
# The afk route is untouched: the agent@amy and grmpf@amy keys, afk, herdr
# and the swarm stay as they are. Nothing here restarts the containers.
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
  root = "/var/lib/nixos-containers/asof-agents";
  out = "/var/lib/nmm-remote-skills";
  skillRoot = "${out}/skills";
  knownHosts = "${out}/known_hosts";
  key = config.clan.core.vars.generators.dave-hermes-nmm-ssh.files.key.path;
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

  # `ssh asof-agents`, for dave-hermes only. StrictHostKeyChecking against
  # the guest's own host key (written by the export from the guest's
  # /etc/ssh). From som's stable public address (networking.publicIPv6),
  # not a rotating temporary one, so nmm can pin the key with from=.
  programs.ssh.extraConfig = ''
    Match host asof-agents localuser ${agent}
      HostName ${address}
      User agent
      IdentityFile ${key}
      IdentitiesOnly yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${knownHosts}
      HostKeyAlias asof-agents
      BindAddress ${somAddress}
      ForwardAgent no
  '';

  users.groups.nmm-remote = { };
  users.users.${agent}.extraGroups = [ "nmm-remote" ];

  services.hyperhermes.agents.${agent}.skillDirs = [ skillRoot ];

  systemd.tmpfiles.rules = [
    "d ${out} 0755 root root -"
    "d ${skillRoot} 0750 root nmm-remote -"
  ];

  systemd.services.nmm-remote-skills = {
    description = "Export the skills afk sees in asof-agents (nmm) for dave-hermes";
    # Skipped while the container is down (its root is then empty).
    unitConfig.ConditionPathExists = "${root}/home/agent/nmm/.git";
    path = [
      pkgs.git
      pkgs.rsync
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs [
        "${pkgs.python3}/bin/python3"
        "${./dave-hermes-nmm/export.py}"
        root
        skillRoot
        knownHosts
        "${./dave-hermes-nmm/SKILL-head.md}"
        "asof-agents"
        "nmm-remote"
      ];
      # Root for reading the container's files only: no write, no exec of
      # anything there, no network.
      CapabilityBoundingSet = [
        "CAP_DAC_READ_SEARCH"
        "CAP_CHOWN"
        "CAP_FOWNER"
      ];
      AmbientCapabilities = [ ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      # Of /var/lib only the container's root (read-only) and the output:
      # never the asof container's root (its secrets) or the agents' state,
      # whatever the agent links its repo to; no /run (clan secrets).
      TemporaryFileSystem = [
        "/var/lib"
        "/run"
      ];
      BindReadOnlyPaths = [ root ];
      BindPaths = [ out ];
      PrivateTmp = true;
      PrivateNetwork = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallFilter = [ "@system-service" ];
      SystemCallArchitectures = "native";
      TimeoutStartSec = "2min";
      MemoryMax = "1G";
    };
  };
  systemd.timers.nmm-remote-skills = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitInactiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
  };
}
