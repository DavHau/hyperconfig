# Snapshots of nas' encrypted datasets, by sanoid.
#
# clan-core enables services.zfs.autoSnapshot (zfstools) fleet-wide, but it
# only snapshots datasets with com.sun:auto-snapshot=true, which none on nas
# has, so nothing was ever snapshotted. sanoid is declarative instead.
#
# - pool11/enc itself (not recursive): holds /pool11/enc/clan-backup, the
#   borg repos (~0.2T). A client with a stolen key, or a bad prune, can
#   destroy a repo through `borg serve`; snapshots it cannot touch.
# - pool11/enc/data (21T, homes): hourly/daily/monthly undo.
# - pool11/enc/pool1 and pool11/enc/p3 (5T and 0.4T: media, nextcloud,
#   backups, syncthing, VM zvols) and rpool/enc (a 70G VM zvol), each
#   recursive: mostly static data, so daily and monthly only. A snapshot of
#   a zvol with a refreservation reserves what the zvol references
#   (~140G on pool11, ~60G on rpool).
# - Not pool11/enc/david: backup-manual carries its own snapshot chain
#   (an incremental `zfs receive` target), which sanoid's would break.
# Retention is in snapshots kept; with ~30T free on pool11 (350G on rpool)
# their cost is the data changed within the window (borg compacts land
# after 30 days). sanoid only prunes its own autosnap_* snapshots, so the
# existing manual ones are left alone.
#
# While a root is locked, sanoid does not run at all: the ExecCondition
# below skips the run (a skip, not a failure; automount.service is what
# fails loudly then). Otherwise it would keep taking snapshots of the
# unchanged locked datasets and prune real ones by count. Missed runs are
# not caught up; the next run after the unlock takes them.
{ config, lib, pkgs, ... }:
let
  zfs = config.boot.zfs.package;
  roots = lib.unique (
    map (d: lib.head (lib.splitString "/" d) + "/enc") (lib.attrNames config.services.sanoid.datasets)
  );
  keysLoaded = pkgs.writeShellScript "sanoid-keys-loaded" ''
    for r in ${lib.escapeShellArgs config.encGuard.roots}; do
      ks=$(${zfs}/bin/zfs get -H -o value keystatus "$r")
      if [ "$ks" != available ]; then
        echo "$r is locked (keystatus $ks): no snapshots until automount has unlocked it"
        exit 1
      fi
    done
  '';
in
{
  assertions = [
    {
      # Every snapshotted dataset sits in an encryption root the condition
      # checks.
      assertion = lib.all (r: lib.elem r config.encGuard.roots) roots;
      message = "snapshots.nix: sanoid datasets outside encGuard.roots (${toString roots}).";
    }
  ];

  services.sanoid = {
    enable = true;
    templates.enc = {
      hourly = 24;
      daily = 30;
      monthly = 6;
      yearly = 0;
      autosnap = true;
      autoprune = true;
    };
    templates.bulk = {
      hourly = 0;
      daily = 14;
      monthly = 3;
      yearly = 0;
      autosnap = true;
      autoprune = true;
    };
    datasets = {
      "pool11/enc".useTemplate = [ "enc" ];
      "pool11/enc/data".useTemplate = [ "enc" ];
      "pool11/enc/pool1" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };
      "pool11/enc/p3" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };
      "rpool/enc" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };
    };
  };

  # Exit 1 from an ExecCondition: the run is skipped, the unit not failed.
  systemd.services.sanoid.serviceConfig.ExecCondition = "${keysLoaded}";
}
