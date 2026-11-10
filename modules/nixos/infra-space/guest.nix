/*
  The system inside the infra-space container (./default.nix sets the
  options below from the host side). One user, `infra`, with fleet root
  through the shared infra-space key; hermes and afk plug in through the
  host's hyper.infraSpace.guestModules.

  Not hyperhermes' nixosModules.slot: it expects the slots host (keys and
  host key bind-mounted under /var/lib/container-slot), which this host is
  not. Plain sshd instead, key-only, `infra` only.

  Secrets: every credential the host passes (hyper.infraSpace.credentials)
  is a system credential here, for guest units to take with
  LoadCredential=<name>; infra-space-secrets.service also installs each at
  /run/infra-space/secrets/<name>, owner infra, 0400, for the interactive
  user and the tools it runs (ssh, git, clan). /run is the guest's
  own tmpfs: nothing secret sits on a path bound from the host.

  TPM: /dev/tpmrm0 is the host's, which grants `infra` (only) access on
  it (./default.nix). infra's age identity, sealed to it, lives at
  ~/.config/age/identities: made here once per member, never copied out.
  It decrypts the clan vars (their recipients: ./age-recipients.nix).

  Clan vars store: clan's external age store, the git checkout
  ~/clan-secrets of DavHau/hyperconfig-secrets, into which clan commits
  every var it writes. Only the `clan` on PATH (a wrapper, below) points
  clan at it (CLAN_AGE_STORE_DIR, set nowhere else): any other clan (the
  devshell's, first on PATH where direnv loads hyperconfig's .envrc)
  fails for want of it instead of running on a store out of sync. Both
  instances and Dave write to it, so it is kept in sync with GitHub's
  main by clan-secrets-sync: `pull` rebases local commits onto it, `push`
  pushes them, never forced. Run by the wrapper (pull before, push after
  the real clan, holding the sync's lock throughout) and by
  infra-space-secrets-push on every commit and every 5 minutes, so
  commits made otherwise go up too; a run fired while the wrapper holds
  the lock (clan's own commits) does nothing: the wrapper's push takes
  them up. A conflict (one var written on both sides) is never resolved
  here: the rebase is aborted, the run fails and the push unit stays
  failed, which makes the wrapper refuse until infra resolves it by hand
  (./hermes-skill/SKILL.md, "Secrets store conflict").

  Inbound: the firewall admits the host's veth addresses (hostAddress,
  hostAddress6), on every port, and nothing else; sshd opens no port of
  its own. The host's ssh proxy and services the host fronts (som's nginx)
  connect from there; a LAN peer routing to the guest through the host
  is refused here as well as on the host (./default.nix).
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.infraSpace;
  secretsDir = "/run/infra-space/secrets";
  # bound from the host (./gcroots.nix)
  gcrootSocket = "/run/infra-space-gcroots/socket";
  home = "/home/infra";
  # Commits from each instance say which one made them.
  identity = {
    name = "infra-space (${cfg.member})";
    email = "infra-space@${cfg.member}.d";
  };
  # The checkouts each instance works in: hyperconfig, and the clan vars'
  # encrypted store, reached through its own deploy key (the ssh alias
  # below).
  secretsHost = "github-secrets";
  checkouts = {
    hyperconfig = {
      repo = "git@github.com:DavHau/hyperconfig.git";
      dir = "hyperconfig";
    };
    secrets = {
      repo = "${secretsHost}:DavHau/hyperconfig-secrets.git";
      dir = "clan-secrets";
    };
  };
  secretsStore = "${home}/${checkouts.secrets.dir}";
  pushUnit = "infra-space-secrets-push.service";
  runbook = ''the infra-space skill (modules/nixos/infra-space/hermes-skill/SKILL.md), section "Secrets store conflict"'';

  # The clan vars store's sync with GitHub (see the header); one run at a
  # time (the wrapper, the push unit and infra by hand run it). The
  # wrapper and the push unit hold the lock across both their runs and
  # tell them so (CLAN_SECRETS_SYNC_LOCKED=1).
  secretsSync = pkgs.writeShellApplication {
    name = "clan-secrets-sync";
    runtimeInputs = [
      pkgs.git
      pkgs.openssh
      pkgs.util-linux
    ];
    text = ''
      store=${secretsStore}
      if ! cd "$store" 2>/dev/null; then
        echo "clan-secrets-sync: no secrets store checkout at $store (infra-space-clone-secrets.service makes it)" >&2
        exit 1
      fi
      export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
      if [ "''${CLAN_SECRETS_SYNC_LOCKED:-}" != 1 ]; then
        exec 9>"$(git rev-parse --git-dir)/clan-secrets-sync.lock"
        flock 9
      fi
      # clan commits to HEAD; only main is synced.
      if [ "$(git symbolic-ref -q HEAD || true)" != refs/heads/main ]; then
        echo "clan-secrets-sync: $store is not on branch main; switch back to it (git switch main)" >&2
        exit 1
      fi

      case "''${1:-}" in
        pull)
          # Exit 2: GitHub has no main yet; the first push makes it.
          rc=0
          git ls-remote --exit-code origin refs/heads/main >/dev/null || rc=$?
          if [ "$rc" = 2 ]; then
            exit 0
          elif [ "$rc" != 0 ]; then
            exit "$rc"
          fi
          # No `+`: a rewritten upstream main fails here instead of
          # being followed.
          git fetch --quiet origin refs/heads/main:refs/remotes/origin/main
          if ! git rev-parse -q --verify refs/heads/main >/dev/null; then
            # cloned while GitHub had no main: take it as it is now
            git merge --quiet --ff-only refs/remotes/origin/main
          elif ! git rebase --quiet refs/remotes/origin/main; then
            if [ -e "$(git rev-parse --git-path rebase-merge)" ] || [ -e "$(git rev-parse --git-path rebase-apply)" ]; then
              mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
              git rebase --abort
              {
                echo "clan-secrets-sync: local commits in $store conflict with GitHub's main in:"
                printf '  %s\n' "''${conflicts[@]}"
                echo "The rebase was aborted: main is back at the local commits, nothing is lost."
                echo ${lib.escapeShellArg "Resolve it by hand: ${runbook}."}
              } >&2
            fi
            exit 1
          fi
          ;;
        push)
          git rev-parse -q --verify refs/heads/main >/dev/null || exit 0
          if git rev-parse -q --verify refs/remotes/origin/main >/dev/null \
            && [ "$(git rev-list --count refs/remotes/origin/main..refs/heads/main)" = 0 ]; then
            exit 0
          fi
          git push --quiet origin refs/heads/main:refs/heads/main
          ;;
        *)
          echo "usage: clan-secrets-sync pull|push" >&2
          exit 2
          ;;
      esac
    '';
  };

  # The `clan` on PATH: the real one between a pull and a push of the
  # store, so every clan run starts from GitHub's vars and leaves its own
  # there. Fails loudly instead of running on a store out of sync.
  # With buildOnHost (som), `clan machines update` builds here, which is
  # the host's nix-daemon, and uploads the closures to the targets: the
  # wrapper adds `--build-host localhost` unless the caller names one.
  clanWrapper = pkgs.writeShellApplication {
    name = "clan";
    text = ''
      ${lib.optionalString cfg.buildOnHost ''
        # clan's top-level parser takes no options: the subcommand is
        # always $1 $2 (with their aliases m, u).
        case "''${1:-} ''${2:-}" in
          "machines update" | "machines u" | "m update" | "m u")
            named=0
            for arg in "''${@:3}"; do
              case "$arg" in
                --build-host | --build-host=*) named=1 ;;
              esac
            done
            # right after the subcommand, so a `--` later stays last
            [ "$named" = 1 ] || set -- "$1" "$2" --build-host localhost "''${@:3}"
            ;;
        esac
      ''}
      export CLAN_AGE_STORE_DIR=${secretsStore}
      store=$CLAN_AGE_STORE_DIR
      # The sync's lock for the whole run (pull, clan, push), waited for:
      # the push unit, fired by clan's commits, skips instead of running
      # under clan (secretsPush below). No checkout: the pull below says so.
      if git_dir=$(${pkgs.git}/bin/git -C "$store" rev-parse --absolute-git-dir 2>/dev/null); then
        exec 9>"$git_dir/clan-secrets-sync.lock"
        ${pkgs.util-linux}/bin/flock 9
        export CLAN_SECRETS_SYNC_LOCKED=1
      fi
      if ${config.systemd.package}/bin/systemctl is-failed --quiet ${pushUnit}; then
        {
          echo "clan: ${pushUnit} failed: the secrets store may be out of sync with GitHub. Refusing to run."
          echo "See journalctl -u ${pushUnit}; once its cause is fixed, systemctl start ${pushUnit}."
          echo ${lib.escapeShellArg "If it lists conflicting files, follow ${runbook}."}
        } >&2
        exit 1
      fi
      if ! ${lib.getExe secretsSync} pull; then
        echo "clan: refusing to run on a secrets store out of sync with GitHub" >&2
        exit 1
      fi
      rc=0
      # neither the lock nor the variable for clan and what it starts
      ${pkgs.coreutils}/bin/env -u CLAN_SECRETS_SYNC_LOCKED ${cfg.clanPackage}/bin/clan "$@" 9>&- || rc=$?
      if ! ${lib.getExe secretsSync} push; then
        echo "clan: pushing the secrets store failed; its new commits are only in $CLAN_AGE_STORE_DIR" >&2
        [ "$rc" != 0 ] || rc=1
      fi
      exit "$rc"
    '';
  };

  # infra-space-secrets-push's run: pull, then push, under one try of the
  # lock. Never waits for it: the holder is a wrapped clan run, which can
  # outlast the unit's start timeout (`clan machines update`), and a unit
  # killed waiting would stay failed and block the wrapper. The wrapper's
  # push covers the commits that fired this run, so skipping is a success.
  secretsPush = pkgs.writeShellApplication {
    name = "infra-space-secrets-push";
    runtimeInputs = [
      pkgs.git
      pkgs.util-linux
    ];
    text = ''
      cd ${secretsStore}
      exec 9>"$(git rev-parse --git-dir)/clan-secrets-sync.lock"
      if ! flock -n 9; then
        echo "a clan run holds the secrets store; its own push takes these commits up"
        exit 0
      fi
      export CLAN_SECRETS_SYNC_LOCKED=1
      # in order, the push only after a successful pull
      ${lib.getExe secretsSync} pull
      ${lib.getExe secretsSync} push
    '';
  };

  aliasOf = member: "infra-space-${member}";

  # The host's GC roots for this guest's builds (./gcroots.nix): the
  # guest's own result links are no roots there. Sends `<machine> <drv>`
  # to the host's root-owned socket, prints its answer, fails unless it
  # rooted.
  gcroot = pkgs.writeShellApplication {
    name = "infra-space-gcroot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.socat
      config.nix.package
    ];
    text = ''
      usage() {
        echo "usage: infra-space-gcroot <machine> [<drv> | <built system or result link>]" >&2
        echo "  without a path: the toplevel of .#nixosConfigurations.<machine> of the flake here" >&2
        exit 2
      }
      [ $# = 1 ] || [ $# = 2 ] || usage
      machine=$1
      if [ $# = 1 ]; then
        drv=$(nix eval --raw ".#nixosConfigurations.$machine.config.system.build.toplevel.drvPath")
      else
        path=$(readlink -f -- "$2")
        case "$path" in
          *.drv) drv=$path ;;
          *) drv=$(nix-store -q --deriver "$path") ;;
        esac
      fi
      socket=${gcrootSocket}
      [ -S "$socket" ] || { echo "infra-space-gcroot: no $socket: this host keeps no roots for the guest" >&2; exit 1; }
      # the host waits out a running collection (up to 2 h)
      reply=$(printf '%s %s\n' "$machine" "$drv" | socat -t 7300 -T 7300 - "UNIX-CONNECT:$socket")
      echo "$reply"
      case "$reply" in
        "ok "*) exit 0 ;;
      esac
      exit 1
    '';
  };

  githubHostKeys = import ../../github-host-keys.nix;

  # Into a temporary directory first, so a failed clone leaves nothing
  # that would stop the next attempt (the timer below, every 15 min).
  clone =
    { repo, dir }:
    pkgs.writeShellScript "infra-space-clone-${dir}" ''
      set -eu
      tmp=$(mktemp -d ${home}/.${dir}-clone.XXXXXX)
      trap 'rm -rf "$tmp"' EXIT
      # An empty remote (no commits yet: the secrets repo before its first
      # push) has no main to check out; it is cloned as it is, on an unborn
      # main the first push creates.
      if ! git clone --quiet --branch main ${repo} "$tmp/${dir}"; then
        if [ -n "$(git ls-remote --heads ${repo})" ] || ! git clone --quiet ${repo} "$tmp/${dir}"; then
          echo "cloning ${repo} failed (deploy key not registered, or no network?); trying again in 15 min" >&2
          exit 0
        fi
        git -C "$tmp/${dir}" symbolic-ref HEAD refs/heads/main
      fi
      (cd "$tmp/${dir}" && jj git init --colocate)
      mv "$tmp/${dir}" ${home}/${dir}
    '';

  # Absent until the clone succeeds: it is retried at boot and every 15
  # minutes until the checkout exists (then the condition skips it).
  cloneService = checkout: {
    description = "Clone ${checkout.dir} for infra";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    requires = [ "infra-space-secrets.service" ];
    after = [
      "network-online.target"
      "infra-space-secrets.service"
    ];
    unitConfig.ConditionPathExists = "!${home}/${checkout.dir}";
    path = [
      pkgs.git
      pkgs.jujutsu
      pkgs.openssh
      pkgs.coreutils
    ];
    environment = {
      GIT_SSH_COMMAND = "ssh -o BatchMode=yes";
      JJ_USER = identity.name;
      JJ_EMAIL = identity.email;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "infra";
      Group = "infra";
      WorkingDirectory = home;
      ExecStart = clone checkout;
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
  # The base every space shares (../spaces/guest-base.nix): resolver,
  # inbound rule, the user `infra`, the credentials, sshd; and through it
  # Dave's shell (fish, aliases, zoxide, direnv, tmux) for the launcher
  # sessions.
  # (shell-profile first: the base imports it too, and this order keeps
  # the guest's package list as it was before the base was factored out.)
  imports = [
    ../shell-profile.nix
    ../spaces/guest-base.nix
    # off unless the dashboard is published (./dashboard.nix)
    ./secret-prompt
  ];

  options.infraSpace = {
    member = lib.mkOption {
      type = lib.types.str;
      description = "The host's name among the members.";
    };
    uid = lib.mkOption {
      type = lib.types.int;
      description = "uid and gid of `infra` (owns the host's state directory).";
    };
    credentials = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Names of the credentials the host passes in, installed for `infra`.";
    };
    hostKeyCredential = lib.mkOption {
      type = lib.types.str;
      description = "Name of the credential holding sshd's host key.";
    };
    members = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      description = "Every member: { address, sshPort, hostKey } (the host's hyper.infraSpace.members).";
    };
    sshPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "The shared infra-space identity.";
    };
    adminKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Dave's keys.";
    };
    fleetCertAuthority = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = "{ publicKey, hostNames } of the CA certifying the fleet's host keys.";
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
      description = "The host's /etc/hosts additions (`<machine>.d` from clan yggdrasil).";
    };
    buildOnHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Make the `clan` wrapper pass `--build-host localhost` to every `clan machines update` that names no build host (the host's hyper.infraSpace.buildOnHost).";
    };
    clanPackage = lib.mkOption {
      type = lib.types.package;
      default = inputs.clan-core.packages.${pkgs.stdenv.hostPlatform.system}.clan-cli;
      defaultText = lib.literalExpression "inputs.clan-core.packages.\${system}.clan-cli";
      description = "The real clan-cli the `clan` wrapper runs (a stub in ./test.nix).";
    };
    clanWrapper = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = clanWrapper;
      defaultText = lib.literalMD "the `clan` wrapper of ./guest.nix";
      description = "The `clan` on PATH: the real one between a pull and a push of the secrets store.";
    };
  };

  config = {
    space = {
      name = "infra-space";
      user = "infra";
      inherit (cfg)
        uid
        credentials
        hostKeyCredential
        resolver
        hostAddress
        hostAddress6
        extraHosts
        ;
      inherit home;
      description = "infra-space";
      authorizedKeys = [ cfg.sshPublicKey ] ++ cfg.adminKeys;
    };

    # Fleet host keys through the CA the hosts' certificates come from,
    # the members' guests by their pinned keys (HostKeyAlias below), GitHub
    # by its published keys: no prompt anywhere.
    programs.ssh.knownHosts = {
      fleet-ca = {
        certAuthority = true;
        inherit (cfg.fleetCertAuthority) hostNames publicKey;
      };
    }
    // lib.listToAttrs (
      lib.imap0 (
        i: key:
        lib.nameValuePair "github-${toString i}" {
          hostNames = [ "github.com" ];
          publicKey = key;
        }
      ) githubHostKeys
    )
    // lib.mapAttrs' (
      member: m:
      lib.nameValuePair (aliasOf member) {
        hostNames = [ (aliasOf member) ];
        publicKey = m.hostKey;
      }
    ) cfg.members;

    programs.ssh.extraConfig = ''
      ${lib.concatStrings (
        lib.mapAttrsToList (member: m: ''
          Host ${aliasOf member}
            HostName ${m.address}
            Port ${toString m.sshPort}
            User infra
            HostKeyAlias ${aliasOf member}
            IdentityFile ${secretsDir}/ssh
            IdentitiesOnly yes
        '') cfg.members
      )}
      Host github.com
        User git
        IdentityFile ${secretsDir}/github
        IdentitiesOnly yes

      # The secrets repo's own deploy key, against the same pinned keys.
      Host ${secretsHost}
        HostName github.com
        User git
        HostKeyAlias github.com
        IdentityFile ${secretsDir}/secrets-github
        IdentitiesOnly yes

      Host ${lib.concatStringsSep " " cfg.fleetCertAuthority.hostNames}
        User root
        IdentityFile ${secretsDir}/ssh
        IdentitiesOnly yes
    '';

    environment.systemPackages = [
      clanWrapper
      secretsSync
      gcroot
      pkgs.git
      pkgs.jujutsu
      pkgs.openssh
      config.nix.package
      # the TPM age identity (./default.nix, Identities)
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
      config.user = identity;
    };
    environment.variables.JJ_USER = identity.name;
    environment.variables.JJ_EMAIL = identity.email;

    # The checkouts each instance works in (cloneService above).
    systemd.services.infra-space-clone = cloneService checkouts.hyperconfig;
    systemd.timers.infra-space-clone = cloneTimer;
    systemd.services.infra-space-clone-secrets = cloneService checkouts.secrets;
    systemd.timers.infra-space-clone-secrets = cloneTimer;

    # The store's safety net (the header): every commit, however made, and
    # every 5 minutes. A failed run stays failed, and so blocks the `clan`
    # wrapper, until a later one succeeds; infra may start it itself (the
    # polkit rule below), as the conflict runbook in ./hermes-skill/SKILL.md
    # does. Skipped until the checkout exists.
    systemd.services.infra-space-secrets-push = {
      description = "Sync infra's clan secrets store with GitHub";
      wants = [ "network-online.target" ];
      requires = [ "infra-space-secrets.service" ];
      after = [
        "network-online.target"
        "infra-space-secrets.service"
      ];
      unitConfig = {
        ConditionPathExists = "${secretsStore}/.git";
        # A start per commit, and clan commits in bursts (one per
        # re-encrypted file in `clan vars fix`): systemd's default limit
        # (5 in 10 s) would fail it, blocking the wrapper, and the path
        # unit with it, which would stop watching.
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "infra";
        Group = "infra";
        ExecStart = lib.getExe secretsPush;
        # a hung connection would keep it active and the triggers idle
        TimeoutStartSec = "5min";
      };
    };
    # HEAD's reflog: appended to by every commit, rebase and reset on it.
    # No trigger limit (200 in 2 s by default, then failed and no longer
    # watching): a rebase of many local commits writes it that fast.
    systemd.paths.infra-space-secrets-push = {
      wantedBy = [ "paths.target" ];
      pathConfig = {
        PathChanged = "${secretsStore}/.git/logs/HEAD";
        TriggerLimitIntervalSec = 0;
      };
    };
    systemd.timers.infra-space-secrets-push = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "*:0/5";
    };
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "${pushUnit}" &&
            action.lookup("verb") == "start" &&
            subject.user == "infra") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
