/*
  The system inside a named space's container (./default.nix sets
  `space.*` from the host side): the shared base (./guest-base.nix: the
  host's resolver, the inbound rule, the one user, its credentials,
  sshd), plus the tools infra-space has (git, jj, nix, tmux from the
  shell profile, afk from ./afk.nix) and herdr's server, so Dave's herdr
  on his desktop attaches to it as a saved machine (./client.nix): herdr
  finds /run/current-system/sw/bin/herdr over ssh, and its bridge starts
  the server on demand. The same herdr as on the desktops
  (../herdr-jj.nix: the same version, which the client requires, with the
  jj plugin).

  No fleet: no infra-space key, no fleet CA, no `<machine>.d` names. The
  space's own ssh/git targets come with its module (./gi-infra.nix,
  ./agave.nix) as programs.ssh settings over its credentials in
  /run/<name>/secrets.

  `space.tpm`: the host's TPM is bound in (./host.nix) for an age
  identity made here, at ~/.config/age/identities, for the space's own
  clan; age and age-plugin-tpm are on PATH for it.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.space;
  home = cfg.home;

  # Into a temporary directory first, so a failed clone leaves nothing
  # that would stop the next attempt (the timer below, every 15 min);
  # colocated with jj, as infra-space's checkouts.
  clone =
    dir: repo:
    pkgs.writeShellScript "${cfg.name}-clone-${dir}" ''
      set -eu
      tmp=$(mktemp -d ${home}/.${dir}-clone.XXXXXX)
      trap 'rm -rf "$tmp"' EXIT
      if ! git clone --quiet ${repo} "$tmp/${dir}"; then
        echo "cloning ${repo} failed (key not registered on the forge yet, or no network?); trying again in 15 min" >&2
        exit 0
      fi
      (cd "$tmp/${dir}" && jj git init --colocate)
      mv "$tmp/${dir}" ${home}/${dir}
    '';
in
{
  imports = [
    ./guest-base.nix
    ../herdr-jj.nix
  ];

  options.space = {
    tpm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "The host binds its TPM in (age identity tools on PATH).";
    };
    gitIdentity = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "{ name, email } of the space's commits.";
    };
    checkouts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Directory under the home -> git URL: cloned once its key works (retried every 15 min until then), never touched again.";
    };
  };

  config = {
    environment.systemPackages = [
      pkgs.git
      pkgs.jujutsu
      pkgs.openssh
      config.nix.package
    ]
    ++ lib.optionals cfg.tpm [
      pkgs.age
      pkgs.age-plugin-tpm
    ];

    # Builds go through the host's nix-daemon (the container gets its
    # socket); this is only the client's config.
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    programs.git = {
      enable = true;
      config.user = cfg.gitIdentity;
    };
    environment.variables.JJ_USER = cfg.gitIdentity.name;
    environment.variables.JJ_EMAIL = cfg.gitIdentity.email;

    # The space's checkouts: absent until the clone succeeds, retried at
    # boot and every 15 minutes until then (the condition skips it after).
    systemd.services = lib.mapAttrs' (
      dir: repo:
      lib.nameValuePair "${cfg.name}-clone-${dir}" {
        description = "Clone ${dir} for ${cfg.user}";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        requires = [ "${cfg.name}-secrets.service" ];
        after = [
          "network-online.target"
          "${cfg.name}-secrets.service"
        ];
        unitConfig.ConditionPathExists = "!${home}/${dir}";
        path = [
          pkgs.git
          pkgs.jujutsu
          pkgs.openssh
          pkgs.coreutils
        ];
        environment = {
          GIT_SSH_COMMAND = "ssh -o BatchMode=yes";
          JJ_USER = cfg.gitIdentity.name;
          JJ_EMAIL = cfg.gitIdentity.email;
        };
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.user;
          WorkingDirectory = home;
          ExecStart = clone dir repo;
        };
      }
    ) cfg.checkouts;
    systemd.timers = lib.mapAttrs' (
      dir: _:
      lib.nameValuePair "${cfg.name}-clone-${dir}" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15min";
          OnUnitInactiveSec = "15min";
        };
      }
    ) cfg.checkouts;
  };
}
