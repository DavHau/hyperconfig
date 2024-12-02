{pkgs, ...}: {
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", ATTR{status}=="Discharging", ATTR{capacity}=="[0-3]", RUN+="${pkgs.systemd}/bin/systemctl poweroff"
  ''
  # sculfun laser engraver
  + ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="1a86", ATTR{idProduct}=="7523", MODE="0777"
  '';
}
