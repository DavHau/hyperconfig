{config, lib, pkgs, ...}:
{
  # don't backup on battery
  systemd.services.borgbackup-job-laptop.serviceConfig.ExecCondition =
    ''${pkgs.gnugrep}/bin/grep -vq Discharging /sys/class/power_supply/BAT1/status'';

  services.borgbackup.jobs.laptop = {
    exclude = import ../../modules/backup-exclude.nix;
    environment.BORG_HOST_ID = "nas";
    user = "root";
    doInit = false;
    repo = "backup@192.168.194.2:/pool11/enc/data/home/backup/notebook";
    environment.BORG_RELOCATED_REPO_ACCESS_IS_OK = "y";
    encryption.mode = "repokey";
    encryption.passCommand =
      ''ssh backup@192.168.194.2 'cat pw.txt' '';
    paths = [
      "/home"
    ];
    compression = "zstd,5";
    startAt = "hourly";
    prune.keep = {
      within = "1w"; # Keep all archives from the last week
      daily = 30;  # one month
      weekly = 4 * 6; # 6 months
      monthly = 12;  # one year
      yearly = 5;
    };
  };
}
