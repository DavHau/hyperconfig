{ config, lib, pkgs, ... }: {
  services.udev.extraRules =
  # sculfun laser engraver
  ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="1a86", ATTR{idProduct}=="7523", MODE="0664"
  ''
  # betaflight configurator. The blanket tty-chown only makes sense (and
  # only resolves) on machines that have the grmpf account — on others it
  # produced "Failed to resolve user 'grmpf'" noise on every udev pass
  # (seen on vit, which runs as dave).
  + lib.optionalString (config.users.users ? grmpf) ''
    SUBSYSTEM=="tty", OWNER="grmpf"
  ''
  + ''
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="2e3c", ATTRS{idProduct}=="df11", MODE="0664", GROUP="dialout"
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", MODE="0664", GROUP="dialout"
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE="0664", GROUP="dialout"
  ''
  ;
}
