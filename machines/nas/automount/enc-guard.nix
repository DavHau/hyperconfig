# Unlock ZFS encryption roots through clevis/tang, and keep everything that
# writes to them away from the bare directories underneath while they are
# locked.
#
# Why: on nas, pool11/enc stayed locked for a month after a power outage
# while services went on writing into the empty mountpoint, i.e. onto the
# unencrypted parent dataset (a whole new borg repo of amy's backups, home
# skeletons). Three layers keep that from happening again:
#
# 1. `automount.service` decrypts the passphrase (a clevis JWE bound to a
#    tang server), loads the keys of `roots`, mounts them and then checks
#    every entry of `mounts`; anything missing fails the unit loudly.
#    With the keys already loaded it only mounts and checks, so restarting
#    it on a deploy is a no-op.
# 2. Every writer is gated: each service in `services` runs `enc-guard`
#    first (ExecStartPre), which refuses to start it unless the right ZFS
#    dataset is mounted at each path it writes to. Borg repos under a root
#    get the same guard in their ssh forced command, users with a home
#    under a root are asserted to have createHome = false.
# 3. `enc-underlay-guard.service` marks the directories underneath each
#    root's mountpoint (on the parent dataset, seen through a non-recursive
#    bind mount) immutable, so nothing can create files there even when
#    1 and 2 are bypassed, and fails if it finds files there.
#
# Why ExecStartPre and not systemd's own mount dependencies: ZFS mounts the
# datasets itself, so systemd has no mount unit for /pool11/enc to depend
# on. RequiresMountsFor=/pool11/enc/x only finds /pool11 (the fstab mount
# of the parent), which is exactly the case that went wrong.
# ConditionPathIsMountPoint would skip the unit silently ("condition
# failed" is a success); a writer that cannot run should show up in
# `systemctl --failed` instead, so the guard fails the unit. And a plain
# mountpoint check is not enough either: it must be the expected dataset.
#
# Tested by the `nas-enc-guard` flake check (./test.nix).
{ config, options, lib, pkgs, ... }:
let
  cfg = config.encGuard;
  zfs = config.boot.zfs.package;

  # path -> dataset, longest path first (the order the guard prints in).
  mountList = lib.sort (a: b: lib.stringLength a.path > lib.stringLength b.path) (
    lib.mapAttrsToList (path: dataset: { inherit path dataset; }) cfg.mounts
  );

  # Users owning a borg repo below an encrypted mountpoint.
  guardedRepos = lib.filterAttrs (_: repo: underAnyRoot repo.path) config.services.borgbackup.repos;
  guardedUsers = lib.unique (lib.mapAttrsToList (_: repo: repo.user) guardedRepos);

  # The value at `path` in a raw option definition, with mkIf/mkMerge/
  # mkForce/mkOrder resolved enough to see whether it is set; [ ] if not.
  getDischarged =
    path: v:
    let
      d =
        v:
        if lib.isAttrs v && v ? _type then
          if v._type == "if" then (if v.condition then d v.content else null)
          else if v._type == "merge" then { _merged = map d v.contents; }
          else if v._type == "override" || v._type == "order" then d v.content
          else v
        else v;
      dv = d v;
    in
    if dv == null then [ ]
    else if lib.isAttrs dv && dv ? _merged then lib.concatMap (getDischarged path) dv._merged
    else if path == [ ] then dv
    else if lib.isAttrs dv && dv ? ${lib.head path} then getDischarged (lib.tail path) dv.${lib.head path}
    else [ ];

  under = path: m: path == m.path || lib.hasPrefix "${m.path}/" path;
  underAnyRoot = path: lib.any (m: under path m) mountList;

  # enc-guard PATH...: exit 1 unless, for each PATH, every configured mount
  # that contains it is mounted from its dataset.
  guard = pkgs.writeShellApplication {
    name = "enc-guard";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      fail=0
      for p in "$@"; do
        ${lib.concatMapStrings (m: ''
          case "$p" in
            ${lib.escapeShellArg m.path}|${lib.escapeShellArg m.path}/*)
              # The topmost mount at the path (raw output: one space).
              src=$(findmnt -rn -o SOURCE,FSTYPE --mountpoint ${lib.escapeShellArg m.path} 2>/dev/null | tail -n1 || true)
              if [ "$src" != ${lib.escapeShellArg "${m.dataset} zfs"} ]; then
                echo "enc-guard: ${m.path} is not mounted from ZFS dataset ${m.dataset} (found: ''${src:-nothing}); refusing to touch $p." >&2
                echo "enc-guard: unlock first: systemctl start automount (see ${cfg.docs})" >&2
                fail=1
              fi
              ;;
          esac
        '') mountList}
      done
      exit "$fail"
    '';
  };

  unlockInputs = [
    zfs
    pkgs.clevis
    pkgs.curl # clevis-decrypt-tang calls curl; clevis' wrapper lacks it
    pkgs.coreutils
    pkgs.util-linux
  ];

  # Sets $pass to the passphrase from the JWE at $jwe, or to "" after
  # unlock.attempts failed tries (exponential backoff).
  decrypt = ''
    pass=""
    delay=2
    for attempt in $(seq 1 ${toString cfg.unlock.attempts}); do
      if pass=$(clevis decrypt < "$jwe"); then
        break
      fi
      pass=""
      echo "clevis decrypt failed (attempt $attempt/${toString cfg.unlock.attempts}); tang unreachable? retrying in ''${delay}s" >&2
      if [ "$attempt" -lt ${toString cfg.unlock.attempts} ]; then
        sleep "$delay"
        delay=$(( delay * 2 > ${toString cfg.unlock.maxDelay} ? ${toString cfg.unlock.maxDelay} : delay * 2 ))
      fi
    done
  '';

  automount = pkgs.writeShellApplication {
    name = "enc-automount";
    runtimeInputs = unlockInputs;
    text = ''
      roots=(${lib.escapeShellArgs cfg.roots})

      locked=()
      for r in "''${roots[@]}"; do
        ks=$(zfs get -H -o value keystatus "$r")
        if [ "$ks" = available ]; then
          echo "$r: key already loaded"
        else
          locked+=("$r")
        fi
      done

      if [ "''${#locked[@]}" -gt 0 ]; then
        jwe=${lib.escapeShellArg cfg.jweFile}
        if [ ! -s "$jwe" ]; then
          echo "no clevis JWE at $jwe; unlock by hand (see ${cfg.docs})" >&2
          exit 1
        fi
        ${decrypt}
        if [ -z "$pass" ]; then
          echo "could not decrypt the ZFS passphrase via tang; unlock by hand (see ${cfg.docs})" >&2
          exit 1
        fi
        for r in "''${locked[@]}"; do
          # A failing load-key ends the script here (set -e, pipefail).
          printf '%s\n' "$pass" | zfs load-key "$r"
          echo "$r: key loaded"
        done
        pass=""
      fi

      # Mount everything mountable (already mounted datasets are skipped). A
      # dataset that cannot mount (e.g. an interrupted `zfs receive`) is only
      # warned about; the mounts that matter are checked right after.
      zfs mount -a || echo "warning: some datasets did not mount (see above)" >&2

      ${lib.getExe guard} ${lib.escapeShellArgs (map (m: m.path) mountList)}
      echo "all encrypted datasets mounted"
    '';
  };

  # The unlock path end to end, without touching anything: decrypt the JWE
  # through tang and have ZFS check the passphrase against every root
  # (`zfs load-key -n` verifies it even while the key is loaded; it loads
  # and mounts nothing). Catches a dead tang, a rotated tang key or a
  # passphrase changed without re-binding, before the next reboot needs it.
  selftest = pkgs.writeShellApplication {
    name = "enc-unlock-selftest";
    runtimeInputs = unlockInputs;
    text = ''
      jwe=${lib.escapeShellArg cfg.jweFile}
      if [ ! -s "$jwe" ]; then
        echo "no clevis JWE at $jwe; the next boot cannot unlock by itself (see ${cfg.docs})" >&2
        exit 1
      fi
      ${decrypt}
      if [ -z "$pass" ]; then
        echo "could not decrypt the ZFS passphrase via tang; the next boot cannot unlock by itself (see ${cfg.docs})" >&2
        exit 1
      fi
      rc=0
      for r in ${lib.escapeShellArgs cfg.roots}; do
        if printf '%s\n' "$pass" | zfs load-key -n "$r"; then
          echo "$r: passphrase from tang is correct"
        else
          echo "$r: the passphrase from tang does not unlock it; re-bind (see ${cfg.docs})" >&2
          rc=1
        fi
      done
      pass=""
      exit "$rc"
    '';
  };

  underlayGuard = pkgs.writeShellApplication {
    name = "enc-underlay-guard";
    runtimeInputs = [
      zfs
      pkgs.coreutils
      pkgs.e2fsprogs # chattr
      pkgs.findutils
      pkgs.util-linux
    ];
    text = ''
      rc=0
      for r in ${lib.escapeShellArgs cfg.roots}; do
        parent=''${r%/*}
        mnt=$(zfs get -H -o value mountpoint "$r")
        pmnt=$(zfs get -H -o value mountpoint "$parent")
        if [ "$(zfs get -H -o value mounted "$parent")" != yes ]; then
          echo "$r: parent dataset $parent is not mounted; cannot check the directory under $mnt" >&2
          rc=1
          continue
        fi
        case "$mnt" in
          "$pmnt"/*) rel=''${mnt#"$pmnt"/} ;;
          *) echo "$r: mountpoint $mnt is not below $parent's $pmnt; skipped" >&2; rc=1; continue ;;
        esac
        # A non-recursive bind mount shows the parent dataset alone: the
        # directory under the mountpoint, whether $r is mounted or not.
        view=$(mktemp -d /run/enc-underlay-guard/view.XXXXXX)
        mount --bind "$pmnt" "$view"
        dir="$view/$rel"
        mkdir -p "$dir"
        leftovers=$(find "$dir" -mindepth 1 ! -type d -printf '%P\n' | head -n 20 || true)
        if [ -n "$leftovers" ]; then
          echo "$r: files on the unencrypted parent $parent under $mnt (written while $r was locked):" >&2
          echo "$leftovers" >&2
          echo "$r: move them into the dataset, then delete them (chattr -R -i first), see ${cfg.docs}" >&2
          rc=1
        fi
        # Immutable directories: no new entries, no renames, no deletes, for
        # root too. Mounting over them is unaffected.
        find "$dir" -type d -exec chattr +i {} +
        echo "$r: directories under $mnt on $parent are immutable"
        umount "$view"
        rmdir "$view"
      done
      exit "$rc"
    '';
  };
in
{
  options.encGuard = {
    roots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        ZFS encryption roots unlocked with the passphrase in `jweFile`
        (one passphrase for all). Each must sit directly below a mounted
        parent dataset.
      '';
    };
    mounts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = ''
        Mountpoint -> dataset that must be mounted there before anything
        may write below the mountpoint. automount.service fails unless all
        of them are mounted.
      '';
    };
    jweFile = lib.mkOption {
      type = lib.types.str;
      description = "clevis JWE (tang pin) holding the passphrase of `roots`.";
    };
    unlock.attempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "clevis decrypt attempts per automount run (exponential backoff).";
    };
    unlock.maxDelay = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Upper bound of the backoff between attempts, in seconds.";
    };
    unlock.restartSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "automount.service restarts this long after a failed run.";
    };
    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = ''
        systemd service -> the paths below `mounts` it writes to. The
        service waits for automount.service, is started by it, and fails
        unless its paths are mounted.
      '';
    };
    selftest.onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = ''
        When enc-unlock-selftest.service checks that the JWE still decrypts
        via tang to the passphrase of every root (randomized by up to 1h,
        caught up after downtime). It fails, visibly in `systemctl
        --failed`, while the next boot could not unlock by itself.
      '';
    };
    docs = lib.mkOption {
      type = lib.types.str;
      default = "the encGuard module";
      description = "Where the manual fallback is documented (shown in errors).";
    };
    guardPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = guard;
      description = "The enc-guard command.";
    };
  };

  config = {
    assertions =
      lib.mapAttrsToList (name: u: {
        assertion = !(u.createHome && underAnyRoot u.home);
        message = "encGuard: users.users.${name}.home (${u.home}) is on an encrypted dataset; set createHome = false so activation never creates it under a locked mountpoint.";
      }) config.users.users
      ++ lib.mapAttrsToList (name: _: {
        assertion = config.systemd.services ? ${name};
        message = "encGuard.services.${name}: no such systemd service.";
      }) cfg.services
      # users.users.<borg user>.openssh.authorizedKeys.keys is replaced
      # with mkForce below: only nixpkgs' borgbackup module (whose keys are
      # rebuilt there) may define it, or other modules' keys would vanish
      # silently. And the result must hold exactly one key per repo key.
      ++ lib.concatMap (
        user:
        let
          keysOf = def: getDischarged [ user "openssh" "authorizedKeys" "keys" ] def.value;
          others = lib.filter (
            def:
            !(lib.hasSuffix "/enc-guard.nix" def.file)
            && !(lib.hasSuffix "/services/backup/borgbackup.nix" def.file)
            && keysOf def != [ ]
          ) options.users.users.definitionsWithLocations;
          expected = lib.foldl' (n: repo: n + lib.length repo.authorizedKeys + lib.length repo.authorizedKeysAppendOnly) 0 (
            lib.filter (repo: repo.user == user) (lib.attrValues config.services.borgbackup.repos)
          );
          actual = lib.length config.users.users.${user}.openssh.authorizedKeys.keys;
        in
        [
          {
            assertion = others == [ ];
            message = "encGuard: users.users.${user}.openssh.authorizedKeys.keys is also set in ${lib.concatMapStringsSep ", " (d: d.file) others}; enc-guard.nix replaces it with mkForce (borg forced commands with the guard), so those keys would be dropped. Add them there.";
          }
          {
            assertion = actual == expected;
            message = "encGuard: users.users.${user} has ${toString actual} authorized keys, expected ${toString expected} (one per borg repo key).";
          }
        ]
      ) guardedUsers
      ++ lib.flatten (
        lib.mapAttrsToList (
          name: paths:
          map (p: {
            assertion = underAnyRoot p;
            message = "encGuard.services.${name}: ${p} is not below any encGuard.mounts entry.";
          }) paths
        ) cfg.services
      );

    environment.systemPackages = [ guard ];

    systemd.services =
      {
        automount = {
          description = "Unlock and mount the encrypted ZFS datasets (clevis/tang)";
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "zfs-import.target"
            "zfs-mount.service"
          ];
          wantedBy = [ "multi-user.target" ];
          # Restart on failure until it works (tang back after an outage):
          # the guarded services stay down meanwhile, and come up with it.
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = cfg.unlock.restartSec;
            TimeoutStartSec = "30min";
            ExecStart = lib.getExe automount;
          };
        };

        enc-unlock-selftest = {
          description = "Check that tang still unlocks the encrypted ZFS roots (dry run)";
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "zfs-import.target"
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe selftest;
          };
        };

        enc-underlay-guard = {
          description = "Keep the directories under the encrypted mountpoints immutable";
          after = [
            "zfs-import.target"
            "zfs-mount.service"
          ];
          before = [ "automount.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            PrivateMounts = true;
            RuntimeDirectory = "enc-underlay-guard";
            ExecStart = lib.getExe underlayGuard;
          };
        };
      }
      # Ordered after automount and started by it once it succeeds. No
      # Wants= on it: a writer's restart loop must not re-trigger the unlock.
      // lib.mapAttrs (_: paths: {
        after = [ "automount.service" ];
        wantedBy = [ "automount.service" ];
        serviceConfig.ExecStartPre = lib.mkBefore [
          "${lib.getExe guard} ${lib.escapeShellArgs paths}"
        ];
      }) cfg.services;

    systemd.timers.enc-unlock-selftest = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.selftest.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # Borg repos below an encrypted mountpoint: gate their repo service, and
    # the ssh forced command, so a client can never `borg init` a new repo
    # into the bare directory (nixpkgs' mkAuthorizedKey plus the guard).
    encGuard.services = lib.mapAttrs' (
      name: repo: lib.nameValuePair "borgbackup-repo-${name}" [ repo.path ]
    ) (lib.filterAttrs (_: repo: underAnyRoot repo.path) config.services.borgbackup.repos);

    users.users =
      let
        allRepos = lib.attrValues config.services.borgbackup.repos;
        mkKeys =
          repo:
          let
            path = lib.escapeShellArg repo.path;
            guardCmd = lib.optionalString (underAnyRoot repo.path) "${lib.getExe guard} ${path} && ";
            restrictedArg = "--restrict-to-${if repo.allowSubRepos then "path" else "repository"} .";
            quotaArg = lib.optionalString (repo.quota != null) "--storage-quota ${repo.quota}";
            mkKey =
              appendOnly: key:
              ''command="${guardCmd}cd ${path} && borg serve ${restrictedArg} ${lib.optionalString appendOnly "--append-only"} ${quotaArg}",restrict ${key}'';
          in
          map (mkKey false) repo.authorizedKeys ++ map (mkKey true) repo.authorizedKeysAppendOnly;
      in
      # The keys of every repo of a user that owns a guarded repo, rebuilt
      # like nixpkgs' mkAuthorizedKey does, with the guard in front.
      lib.genAttrs guardedUsers (user: {
        openssh.authorizedKeys.keys = lib.mkForce (
          lib.concatMap mkKeys (lib.filter (repo: repo.user == user) allRepos)
        );
      });
  };
}
