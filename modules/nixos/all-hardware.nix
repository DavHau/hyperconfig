{
  lib,
  pkgs,
  ...
}: {
  # Machines that list the firmware they load (hyper.firmwareOnly) drop the
  # rest of the redistributable set this pulls in.
  imports = [ ./firmware-only.nix ];
  hardware.enableAllHardware = lib.mkDefault true;
  # Intel VMD (NVMe behind Volume Management Device) only exists on x86;
  # the initrd module shrinker fails hard on a missing module elsewhere.
  boot.initrd.availableKernelModules =
    lib.optional pkgs.stdenv.hostPlatform.isx86 "vmd";
}
