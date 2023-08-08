{config, lib, ...}: let
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
  ];

in {
  services.borgbackup.jobs.laptop = {
    inherit exclude;
    user = "root";
    doInit = false;
    repo = "backup@rhauer.duckdns.org:/pool11/enc/data/home/backup/notebook";
    encryption.mode = "repokey";
    encryption.passCommand =
      ''ssh backup@rhauer.duckdns.org 'cat pw.txt' '';
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
