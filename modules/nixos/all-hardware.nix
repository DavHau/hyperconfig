{
  lib,
  ...
}: {
  hardware.enableAllHardware = lib.mkDefault true;
  boot.initrd.availableKernelModules = [ "vmd" ];
}
