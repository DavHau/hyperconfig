/*
  Cap the ZFS ARC. Unbounded it grows to nearly all of RAM and gives it
  back only under pressure, which shows up as "used" memory and squeezes
  everything else.

  The kernel parameter sets the cap at module load (every boot). The
  oneshot writes the same value into the loaded module, so a switch
  applies a new cap without a reboot (the value is in the unit's script,
  so a changed value changes the unit and the switch restarts it).
*/
{
  config,
  lib,
  ...
}:
let
  cfg = config.hyper.zfsArcMax;
  param = "/sys/module/zfs/parameters/zfs_arc_max";
in
{
  options.hyper.zfsArcMax = lib.mkOption {
    type = lib.types.nullOr lib.types.ints.positive;
    default = null;
    example = 8589934592;
    description = "zfs_arc_max in bytes, at boot and on the running system.";
  };

  config = lib.mkIf (cfg != null) {
    boot.kernelParams = [ "zfs.zfs_arc_max=${toString cfg}" ];

    systemd.services.zfs-arc-max = {
      description = "Set zfs_arc_max to ${toString cfg}";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" ];
      unitConfig.ConditionPathExists = param;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "echo ${toString cfg} > ${param}";
    };
  };
}
