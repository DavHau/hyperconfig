/*
  /tmp on a ZFS dataset instead of tmpfs: on disk, not in RAM, and still
  empty after every boot. The dataset is rolled back to its empty
  snapshot before /tmp is mounted, which is instant however many files it
  held.

  The dataset itself comes from the machine's disko config (mountpoint
  legacy, not auto-snapshotted, plus the empty snapshot `@blank`):

    "root/nobackup/tmp" = {
      type = "zfs_fs";
      mountpoint = "/tmp";
      options = { mountpoint = "legacy"; sync = "disabled"; devices = "off"; setuid = "off"; };
      postCreateHook = "zfs snapshot zroot/root/nobackup/tmp@blank";
    };

  On a live pool, create it the same way by hand before switching (disko
  only applies it on a fresh install).
*/
{
  config,
  lib,
  ...
}:
let
  cfg = config.hyper.zfsEphemeralTmp;
  zfs = "${config.boot.zfs.package}/bin/zfs";
in
{
  options.hyper.zfsEphemeralTmp.dataset = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "zroot/root/nobackup/tmp";
    description = "ZFS dataset mounted on /tmp and rolled back to @blank at every boot.";
  };

  config = lib.mkIf (cfg.dataset != null) {
    assertions = [
      {
        assertion = (config.fileSystems."/tmp".device or null) == cfg.dataset;
        message = "hyper.zfsEphemeralTmp: fileSystems.\"/tmp\" must mount ${cfg.dataset}";
      }
    ];

    boot.tmp.useTmpfs = false;

    # nofail: a missing dataset must not drop a remote host into emergency
    # mode. nofail alone also drops the ordering before local-fs.target,
    # and then systemd-tmpfiles-setup and early services run before /tmp is
    # mounted (their files end up hidden under it); keep that ordering.
    fileSystems."/tmp".options = [
      "nofail"
      "x-systemd.before=local-fs.target"
    ];

    systemd.services.tmp-rollback = {
      description = "Reset ${cfg.dataset} to its empty snapshot";
      # Wanted, not required: a failed rollback leaves last boot's files and
      # a failed unit, but /tmp still mounts. Without /tmp every unit with
      # PrivateTmp (dbus among them) fails, and a remote host is lost.
      wantedBy = [ "tmp.mount" ];
      before = [ "tmp.mount" ];
      after = [ "zfs-import.target" ];
      wants = [ "zfs-import.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # Only ever on the unmounted dataset: a rollback of a mounted /tmp
      # would wipe it under running processes.
      script = ''
        if [ "$(${zfs} get -H -o value mounted ${cfg.dataset})" = yes ]; then
          echo "${cfg.dataset} is mounted; not rolling back"
          exit 0
        fi
        ${zfs} rollback -r ${cfg.dataset}@blank
      '';
    };
  };
}
