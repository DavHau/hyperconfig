{config, lib, pkgs, ...}: let
  exclude = [
    "/home/**/cache/"
    "/home/*/.cabal"
    "/home/*/.cache"
    "/home/*/.cargo"
    "/home/*/.config/Ferdium/Cache"
    "/home/*/.config/Ferdium/Partitions"
    "/home/*/.config/Mullvad VPN"
    "/home/*/.config/VSCodium"
    "/home/*/.local/share/containers"
    "/home/*/.local/share/Steam/steamapps/common"
    "/home/*/.local/share/TelegramDesktop"
    "/home/*/.local/share/TelegramDesktop/tdata/user_data/cache"
    "/home/*/.local/state/wireplumber"
    "/home/*/.nix-portable"
    "/home/*/.node-gyp"
    "/home/*/.npm"
    "/home/*/.platformio"
    "/home/*/.stack"
    "/home/*/.vagrant.d"
    "/home/*/.youtube-dl-gui"
    "/home/*/**/DawnCache"  # electron
    "/home/*/**/GPUCache"  # electron
    "/home/*/temp"
    "/home/*/VirtualBox VMs"

    # filter out nix dev-shell builds
    "/home/**/*.o"
    "/home/**/nix/outputs"

    # invokeai models
    "/home/**/invokeai/models"
    "/home/*/.ollama"

    # localai models (manually specified via CLI args)
    "/home/*/.local/share/localai/"
  ];

in {
  # don't backup on battery
  systemd.services.borgbackup-job-laptop.serviceConfig.ExecCondition =
    ''${pkgs.gnugrep}/bin/grep -vq Discharging /sys/class/power_supply/BAT0/status'';

  services.borgbackup.jobs.laptop = {
    inherit exclude;
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
