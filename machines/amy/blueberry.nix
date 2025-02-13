{pkgs, ...}: {
  systemd.user.services.blueberry-tray = {
    description = "Blueberry Tray";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.blueberry}/bin/blueberry-tray";
    };
  };
}
