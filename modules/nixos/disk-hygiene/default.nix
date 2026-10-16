/*
  Keep the disk from filling up (store GC itself: ../fast-nix-gc.nix, via
  ../common.nix):
  - cargo-build-gc: hourly per-user deletion of cargo build dirs whose
    workspace is gone (finished omp worktrees) or that are untouched for
    14 days (see ../rust-build-cache.nix).
  - zpool-capacity-alert: hourly desktop notification while any imported pool
    is at or above 80% capacity (ZFS slows down past that point).
  sbox session state is pruned by sbox's own sbox-gc timer (default-on in
  the sbox module, 7 days).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  threshold = 80;

  cargoBuildGc = pkgs.writeShellApplication {
    name = "cargo-build-gc";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.util-linux
    ];
    text = builtins.readFile ./cargo-build-gc.sh;
  };

  capacityAlert = pkgs.writeShellApplication {
    name = "zpool-capacity-alert";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.libnotify
    ];
    text = ''
      zpool list -H -o name,capacity | while read -r pool cap; do
        if [ "''${cap%\%}" -ge ${toString threshold} ]; then
          echo "$pool is $cap full"
          notify-send -u critical "Disk almost full" "ZFS pool $pool is $cap full"
        fi
      done
    '';
  };
in
{
  systemd.user.services.cargo-build-gc = {
    description = "Delete dead cargo build dirs (workspace gone or untouched for 14 days)";
    environment.CARGO_BUILD_GC_DAYS = "14";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe cargoBuildGc;
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    startAt = "hourly";
  };
  systemd.user.timers.cargo-build-gc.timerConfig.Persistent = true;

  systemd.user.services.zpool-capacity-alert = {
    description = "Warn when a ZFS pool is ${toString threshold}% full";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe capacityAlert;
    };
    startAt = "hourly";
  };
}
