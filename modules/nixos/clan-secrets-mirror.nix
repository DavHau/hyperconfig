# A root-only copy of the clan's encrypted vars store (the private GitHub
# repo hyperconfig-secrets) on every machine but the installer: a bare repo
# at /var/lib/clan-secrets that `git clone /var/lib/clan-secrets` reads as
# root, so the secrets stay reachable with GitHub down or the account gone.
# Applied by the `clan-secrets-mirror` importer instance in
# ../flake-parts/nixosConfigurations.nix.
#
# Only `main` is followed. Upstream history is never lost here: when main
# was rewritten (a force push), the old tip is kept as
# refs/backup/<UTC yyyymmddThhmmssZ> before main follows. Any failure
# leaves the repo as it was and fails the unit, so it shows in
# `systemctl --failed` (and monitoring) instead of going stale silently.
#
# Tested by the `clan-secrets-mirror` flake check (./clan-secrets-mirror-test.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.clanSecretsMirror;
  dir = "/var/lib/clan-secrets";
  deployKey = config.clan.core.vars.generators.clan-secrets-pull.files.id_ed25519;

  # Only GitHub's pinned keys (../github-host-keys.nix), and only these: no
  # trust on first use, no system-wide known_hosts.
  knownHosts = pkgs.writeText "github-known-hosts" (
    lib.concatMapStrings (key: "github.com ${key}\n") (import ../github-host-keys.nix)
  );
  ssh = lib.concatStringsSep " " [
    "ssh"
    "-o BatchMode=yes"
    "-o IdentityFile=${deployKey.path}"
    "-o IdentitiesOnly=yes"
    "-o UserKnownHostsFile=${knownHosts}"
    "-o GlobalKnownHostsFile=/dev/null"
    "-o StrictHostKeyChecking=yes"
    # ./ssh.nix turns on multiplexing fleet-wide with ControlPath
    # ~/.ssh/control/%C; root may have no such directory, and then ssh fails
    # ("unix_listener: cannot bind"). Same choice as ./storagebox.nix.
    "-o ControlMaster=no"
  ];
in
{
  options.clanSecretsMirror.url = lib.mkOption {
    type = lib.types.str;
    default = "git@github.com:DavHau/hyperconfig-secrets.git";
    description = "Repo whose `main` is mirrored; other than GitHub only in the test.";
  };

  config = {
    # One read-only deploy key for the whole fleet; its public half is
    # registered on DavHau/hyperconfig-secrets.
    clan.core.vars.generators.clan-secrets-pull = {
      share = true;
      files.id_ed25519 = { };
      files."id_ed25519.pub".secret = false;
      runtimeInputs = [ pkgs.openssh ];
      script = ''
        ssh-keygen -q -t ed25519 -N "" -C clan-secrets-pull@DavHau/hyperconfig-secrets \
          -f "$out"/id_ed25519
      '';
    };

    systemd.services.clan-secrets-mirror = {
      description = "Mirror the clan secrets repo to ${dir}";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.git
        pkgs.openssh
      ];
      environment.GIT_SSH_COMMAND = ssh;
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "clan-secrets";
        StateDirectoryMode = "0700";
        # A hung connection would keep the unit active and the timer from
        # ever starting it again.
        TimeoutStartSec = "5min";
      };
      script = ''
        set -euo pipefail
        export GIT_DIR=${dir}
        # Once, and again only if broken (a half-done init).
        if ! git rev-parse --git-dir >/dev/null 2>&1; then
          git init --quiet --bare --initial-branch=main
        fi

        # Exit 2: the remote has no main (yet), nothing to mirror.
        rc=0
        remote=$(git ls-remote --exit-code ${lib.escapeShellArg cfg.url} refs/heads/main) || rc=$?
        if [ "$rc" = 2 ]; then
          echo "${cfg.url} has no main yet; nothing to mirror"
          exit 0
        elif [ "$rc" != 0 ]; then
          exit "$rc"
        fi
        old=$(git rev-parse --verify --quiet refs/heads/main || true)
        if [ "''${remote%%[[:space:]]*}" = "$old" ]; then
          exit 0
        fi

        # Objects only; refs move below, in one transaction each.
        git fetch --quiet --no-tags ${lib.escapeShellArg cfg.url} refs/heads/main
        new=$(git rev-parse --verify 'FETCH_HEAD^{commit}')
        if [ -z "$old" ]; then
          git update-ref -m "clan-secrets-mirror: clone" refs/heads/main "$new" ""
          echo "main: new at $new"
          exit 0
        fi
        rc=0
        git merge-base --is-ancestor "$old" "$new" || rc=$?
        if [ "$rc" = 0 ]; then
          git update-ref -m "clan-secrets-mirror: fast-forward" refs/heads/main "$new" "$old"
          echo "main: $old -> $new"
        elif [ "$rc" = 1 ]; then
          backup=refs/backup/$(date -u +%Y%m%dT%H%M%SZ)
          # One transaction: both refs move, or neither.
          printf '%s\n' "create $backup $old" "update refs/heads/main $new $old" \
            | git update-ref -m "clan-secrets-mirror: rewritten upstream" --stdin
          echo "main rewritten upstream: $old -> $new, old tip kept as $backup" >&2
        else
          exit "$rc"
        fi
      '';
    };

    systemd.timers.clan-secrets-mirror = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnCalendar = "*:0/5";
        Persistent = true;
      };
    };
  };
}
