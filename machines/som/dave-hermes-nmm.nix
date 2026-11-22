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
#   - skill: one static skill written here (./dave-hermes-nmm/SKILL.md, no
#     text from the container), only in dave-hermes' profile `nmm`, so its
#     other profiles never see it (a skillDir would reach all of them).
#     hyperhermes can't declare profiles: dave-hermes-nmm-profile.service,
#     as dave-hermes, creates the profile once (`hermes profile create`)
#     and installs the skill file on every switch; nothing else of the
#     profile is touched afterwards. dave-hermes runs without
#     lockedConfig, so profiles/ is its own (no immutable pins).
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
  skill = ./dave-hermes-nmm/SKILL.md;
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

  systemd.services.dave-hermes-nmm-profile = {
    description = "dave-hermes' hermes profile nmm and its nmm skill";
    wantedBy = [ "multi-user.target" ];
    # The `hermes` shim refuses to run while the agent's gateway is down.
    wants = [ "hermes-agent-${agent}.service" ];
    after = [ "hermes-agent-${agent}.service" ];
    restartTriggers = [ skill ];
    path = [ pkgs.coreutils ];
    script = ''
      if [ ! -e ${profile} ]; then
        # As Dave would make it: hermes' own layout and the agent's model.
        /run/current-system/sw/bin/hermes profile create nmm --no-alias \
          --description "Works on Dave's nmm/asof project over ssh asof-agents."
        printf '\n%s\n' "This profile works on Dave's nmm (asof) project in the asof-agents container over ssh; load the nmm skill first." >> ${profile}/SOUL.md
      fi
      test -d ${profile}/skills
      mkdir -p ${profile}/skills/nmm
      install -m 0600 ${skill} ${profile}/skills/nmm/.SKILL.md.new
      mv -f ${profile}/skills/nmm/.SKILL.md.new ${profile}/skills/nmm/SKILL.md
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
