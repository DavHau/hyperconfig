# Daily pull of the storage box's depth archive into the vault's parquet
# dataset. bam-specific in practice (that is where the vault lives), but the
# module is host-agnostic - it only needs /vault/parquet to exist.
#
# Why rclone and not the sshfs mount this imports: measured on the same link
# in the same minute, rclone sustains 6-7 MB/s where the mount manages
# 1-2.5 MB/s. The mount stays for interactive browsing; bulk transfer goes
# over plain SFTP.
#
# Connection budget - the box allows 10 concurrent connections per ACCOUNT
# (Hetzner docs), and the fleet already holds about five of them: one sshfs
# per host (amy, bam, som, vit) plus moneymaker's beast, all on the same
# u632961-sub1 sub-account. Hence the deliberately small transfers/checkers
# below. Measurements also showed parallelism buys nothing on this route
# (8 streams was no faster than 1, 8 parallel files was slower), so the only
# reason for transfers > 1 is to overlap the gap between files.
{ config, pkgs, ... }:
let
  dest = "/vault/parquet/depth";
  vaultDataset = "/vault/parquet";
  # Never let the archive fill the pool: each run stops this far above empty.
  reserveGib = 200;
  transfers = 2;
  checkers = 2;

  sync = pkgs.writeShellApplication {
    name = "storagebox-sync";
    runtimeInputs = [
      pkgs.rclone
      pkgs.coreutils
      pkgs.gawk
      pkgs.util-linux # mountpoint
      pkgs.getent # rclone resolves its config dir through getent
    ];
    text = builtins.readFile ./storagebox-sync.sh;
  };
in
{
  # The password var (shared, one prompt for the whole clan) and the host-key
  # pin both live in the mount module; importing it keeps this self-contained.
  imports = [ ./storagebox.nix ];

  systemd.services.storagebox-sync = {
    description = "pull storagebox depth archive into ${dest}";
    after = [
      "network-online.target"
      "storagebox-mount.service"
    ];
    wants = [ "network-online.target" ];

    environment = {
      # Without HOME rclone cannot find a config dir, logs three errors per
      # invocation and falls back to "/.rclone.conf". StateDirectory below
      # creates this.
      HOME = "/var/lib/storagebox-sync";
      SB_DEST = dest;
      SB_PASSWORD_FILE = config.clan.core.vars.generators.storagebox.files.password.path;
      SB_HOST = "u632961-sub1.your-storagebox.de";
      SB_USER = "u632961-sub1";
      SB_PORT = "23"; # Hetzner documents 23 as faster than 22
      SB_REMOTE_DIR = "depth";
      SB_RESERVE_GIB = toString reserveGib;
      SB_TRANSFERS = toString transfers;
      SB_CHECKERS = toString checkers;
    };

    # RequiresMountsFor is a [Unit] directive: in serviceConfig systemd
    # parsed it as an unknown [Service] key and dropped it, leaving the
    # dataset dependency silently absent (the script's own mountpoint check
    # was all that stood between a stopped pool and a filled root disk).
    unitConfig.RequiresMountsFor = [ vaultDataset ];

    serviceConfig = {
      # NOT oneshot: with oneshot the unit stays "activating" for the whole
      # transfer, so `systemctl start` blocks for as long as the sync runs
      # (days, on the first pass). Type=exec goes active as soon as the
      # process is spawned, and the timer still cannot overlap runs because
      # the unit is active throughout. It also drops the need for
      # TimeoutStartSec=infinity, since that timeout now only covers exec.
      Type = "exec";
      ExecStart = "${sync}/bin/storagebox-sync";
      StateDirectory = "storagebox-sync";
      # bam's cores are budgeted for the inference VM; this is background work.
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.storagebox-sync = {
    description = "daily storagebox depth sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      # Catch up after downtime, and do not have every host in a future
      # fleet hit the box on the same second.
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };
}
