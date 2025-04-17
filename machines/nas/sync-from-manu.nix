{lib, config, pkgs, ...}: {
  # define systemd service that runs rsync in a loop
  systemd.services.rsync = {
    description = "rsync service";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [
      pkgs.openssh
      pkgs.rsync
    ];
    script = ''
      rsync manu@10.241.225.42:/raid/manu/ /pool11/enc/data/home/manu/manuel/current \
        -a \
        --verbose \
        --compress --compress-choice=zstd --compress-level=1 \
        --timeout=60
    '';
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 60;
    };
  };
}
