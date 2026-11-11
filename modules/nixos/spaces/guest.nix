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
  space's own ssh/git targets come with its module (./geninf-space.nix)
  as programs.ssh settings over its credentials in
  /run/<name>/secrets, its forges' API logins (`tea`, for PRs) as
  `space.forges` (./forges.nix).

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

  # Every repository of an org the bot's token sees, listed from the
  # forge's API at each run (/user/repos: the token has no
  # read:organization), each cloned as above into ~/<repo> unless that
  # exists. A repository removed by hand comes back at the next run.
  cloneOrg =
    host: o:
    pkgs.writeShellScript "${cfg.name}-clone-org-${host}" ''
      set -eu
      token=$(cat /run/${cfg.name}/secrets/${o.credential})
      page=1
      repos=""
      while :; do
        # the token through curl's config on stdin, never on a command line
        if ! batch=$(printf 'header = "Authorization: token %s"\n' "$token" \
          | curl -sSf --max-time 60 -K - "https://${host}/api/v1/user/repos?limit=50&page=$page"); then
          echo "listing the repositories on ${host} failed (token not set yet, or no network?); trying again in 15 min" >&2
          exit 0
        fi
        repos="$repos"$'\n'"$(jq -r --arg org ${lib.escapeShellArg o.org} \
          '.[] | select(.owner.login == $org and (.empty | not)) | "\(.name)\t\(.ssh_url)"' <<<"$batch")"
        [ "$(jq length <<<"$batch")" -lt 50 ] && break
        page=$((page + 1))
      done
      while IFS=$'\t' read -r dir url; do
        [ -n "$dir" ] || continue
        case "$dir" in .* | */*) echo "skipping odd repository name $dir" >&2; continue ;; esac
        [ -e ${home}/"$dir" ] && continue
        tmp=$(mktemp -d ${home}/."$dir"-clone.XXXXXX)
        if git clone --quiet "$url" "$tmp/$dir" && (cd "$tmp/$dir" && jj git init --colocate); then
          mv "$tmp/$dir" ${home}/"$dir"
          echo "cloned $dir"
        else
          echo "cloning $url failed; trying again in 15 min" >&2
        fi
        rm -rf "$tmp"
      done <<<"$repos"
    '';

  cloneUnit = description: exec: {
    inherit description;
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    requires = [ "${cfg.name}-secrets.service" ];
    after = [
      "network-online.target"
      "${cfg.name}-secrets.service"
    ];
    path = [
      pkgs.git
      pkgs.jujutsu
      pkgs.openssh
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
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
      ExecStart = exec;
    };
  };
  cloneTimer = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitInactiveSec = "15min";
    };
  };
in
{
  imports = [
    ./guest-base.nix
    ./forges.nix
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
    orgCheckouts = lib.mkOption {
      default = { };
      description = "Forge host (Gitea, https://<host>) -> an org whose every repository the credential's account sees is cloned to ~/<repo> (listed from the API every 15 min; existing directories are never touched).";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            org = lib.mkOption {
              type = lib.types.str;
              description = "The org (owner) whose repositories are cloned.";
            };
            credential = lib.mkOption {
              type = lib.types.str;
              description = "Name of the space credential holding the forge API token.";
            };
          };
        }
      );
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

    assertions = lib.mapAttrsToList (host: o: {
      assertion = lib.elem o.credential cfg.credentials;
      message = "space.orgCheckouts.${host}.credential: `${o.credential}` is not a credential of the ${cfg.name} space";
    }) cfg.orgCheckouts;

    # The space's checkouts: absent until the clone succeeds, retried at
    # boot and every 15 minutes until then (the condition skips it after).
    # The orgs' are listed and cloned at every run.
    systemd.services =
      lib.mapAttrs' (
        dir: repo:
        lib.nameValuePair "${cfg.name}-clone-${dir}" (
          lib.recursiveUpdate (cloneUnit "Clone ${dir} for ${cfg.user}" (clone dir repo)) {
            unitConfig.ConditionPathExists = "!${home}/${dir}";
          }
        )
      ) cfg.checkouts
      // lib.mapAttrs' (
        host: o:
        lib.nameValuePair "${cfg.name}-clone-org-${host}" (
          cloneUnit "Clone the repositories of ${o.org} on ${host} for ${cfg.user}" (cloneOrg host o)
        )
      ) cfg.orgCheckouts;
    systemd.timers =
      lib.mapAttrs' (dir: _: lib.nameValuePair "${cfg.name}-clone-${dir}" cloneTimer) cfg.checkouts
      // lib.mapAttrs' (
        host: _: lib.nameValuePair "${cfg.name}-clone-org-${host}" cloneTimer
      ) cfg.orgCheckouts;
  };
}
