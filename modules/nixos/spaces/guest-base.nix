/*
  The base of every space's guest system (infra-space's ../infra-space/guest.nix
  and the named spaces' ./guest.nix import it): the host's resolver, the
  inbound rule, one login user, the credentials and sshd.

    - Inbound: the firewall admits the host's veth addresses (hostAddress,
      hostAddress6) on every port, and nothing else; sshd opens no port of
      its own. The host's ssh proxy (and services the host fronts) connect
      from there; a LAN peer routing to the guest through the host is
      refused here as well as on the host (./host.nix).
    - Secrets: every credential the host passes is a system credential
      here, for guest units to take with LoadCredential=<name>;
      <name>-secrets.service also installs each at /run/<name>/secrets/<cred>,
      owner the user, 0400, for the interactive user and the tools it runs.
      /run is the guest's own tmpfs: nothing secret sits on a path bound
      from the host. The ssh host key goes to sshd only.
    - sshd: key-only, the one user only, its host key from the credential
      (never one made up here).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.space;
  secretsDir = "/run/${cfg.name}/secrets";
  hostKeyPath = "/run/${cfg.name}/ssh_host_ed25519_key";

  installSecrets = pkgs.writeShellScript "${cfg.name}-secrets" ''
    set -eu
    install -d -m 0755 /run/${cfg.name}
    install -d -m 0500 -o ${cfg.user} -g ${cfg.user} ${secretsDir}
    for name in ${lib.escapeShellArgs cfg.credentials}; do
      install -m 0400 -o ${cfg.user} -g ${cfg.user} "$CREDENTIALS_DIRECTORY/$name" ${secretsDir}/"$name"
    done
    install -m 0600 "$CREDENTIALS_DIRECTORY/${cfg.hostKeyCredential}" ${hostKeyPath}
  '';
in
{
  # Dave's shell (fish, aliases, zoxide, direnv, tmux) for the login sessions.
  imports = [
    ../shell-profile.nix
    ../ghostty-terminfo.nix
  ];

  options.space = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "The space's name: /run/<name>/secrets, <name>-secrets.service.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      description = "The one login user.";
    };
    uid = lib.mkOption {
      type = lib.types.int;
      description = "uid and gid of the user (owns the host's state directory).";
    };
    home = lib.mkOption {
      type = lib.types.str;
      description = "The user's home (bound from the host).";
    };
    description = lib.mkOption {
      type = lib.types.str;
      description = "The user's description.";
    };
    credentials = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Names of the credentials the host passes in, installed for the user.";
    };
    hostKeyCredential = lib.mkOption {
      type = lib.types.str;
      description = "Name of the credential holding sshd's host key.";
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "ssh keys authorized for the user.";
    };
    resolver = lib.mkOption {
      type = lib.types.str;
      description = "DNS server (the host's resolved stub on its veth address).";
    };
    hostAddress = lib.mkOption {
      type = lib.types.str;
      description = "The host's v4 address on the veth; the only v4 source admitted inbound.";
    };
    hostAddress6 = lib.mkOption {
      type = lib.types.str;
      description = "The host's v6 address on the veth; the only v6 source admitted inbound.";
    };
    extraHosts = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "/etc/hosts additions.";
    };
  };

  config = {
    system.stateVersion = "26.05";

    networking.useHostResolvConf = false;
    networking.nameservers = [ cfg.resolver ];
    networking.extraHosts = cfg.extraHosts;

    networking.firewall.extraInputRules = ''
      ip saddr ${cfg.hostAddress} accept
      ip6 saddr ${cfg.hostAddress6} accept
    '';
    networking.firewall.extraCommands = lib.mkIf (config.networking.firewall.backend == "iptables") ''
      iptables -A nixos-fw -s ${cfg.hostAddress} -j nixos-fw-accept
      ip6tables -A nixos-fw -s ${cfg.hostAddress6} -j nixos-fw-accept
    '';

    users.groups.${cfg.user}.gid = cfg.uid;
    users.users.${cfg.user} = {
      isNormalUser = true;
      inherit (cfg) uid home description;
      group = cfg.user;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    systemd.services."${cfg.name}-secrets" = {
      description = "Install ${cfg.name} credentials for ${cfg.user}";
      wantedBy = [ "multi-user.target" ];
      before = [ "systemd-user-sessions.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = cfg.credentials ++ [ cfg.hostKeyCredential ];
        ExecStart = installSecrets;
      };
    };

    services.openssh = {
      enable = true;
      # reached through the host's proxy, admitted by the rules above
      openFirewall = false;
      # The host key arrives as a credential; never one made up here.
      generateHostKeys = false;
      hostKeys = [
        {
          type = "ed25519";
          path = hostKeyPath;
        }
      ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ cfg.user ];
      };
    };
    systemd.services.sshd = {
      requires = [ "${cfg.name}-secrets.service" ];
      after = [ "${cfg.name}-secrets.service" ];
    };
  };
}
