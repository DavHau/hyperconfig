{pkgs, ...}: {
  services.udev.extraRules =
  ''
    SUBSYSTEM=="power_supply", ATTR{status}=="Discharging", ATTR{capacity}=="[0-3]", RUN+="${pkgs.systemd}/bin/systemctl poweroff"
  '';
}
