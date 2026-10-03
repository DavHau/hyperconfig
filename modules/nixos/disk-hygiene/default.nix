/*
  Keep the disk from filling up:
  - fast-nix-gc: daily store GC (generations and stale gcroots/auto entries
    older than 14 days). Replaces nix.gc, which ./nix-gc.nix leaves off.
  - cargo-build-gc: daily per-user deletion of cargo build dirs untouched
    for 14 days (see ../rust-build-cache.nix).
  - zpool-capacity-alert: hourly desktop notification while any imported pool
    is at or above 80% capacity (ZFS slows down past that point).
  sbox session state is pruned by sbox's own sbox-gc timer (default-on in
  the sbox module, 7 days).
*/
{
  inputs,
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
  imports = [ inputs.fast-nix-gc.nixosModules.default ];

  services.fast-nix-gc = {
    enable = true;
    automatic = true;
    dates = "daily";
    randomizedDelaySec = "1h";
    deleteOlderThan = "14d";
    # Keep paths fetched for builds of the last day.
    keepRecent = "1d";
  };

  systemd.user.services.cargo-build-gc = {
    description = "Delete cargo build dirs untouched for 14 days";
    environment.CARGO_BUILD_GC_DAYS = "14";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe cargoBuildGc;
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    startAt = "daily";
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
