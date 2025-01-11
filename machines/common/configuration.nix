{config, lib, pkgs, modulesPath, ...}: {
  imports = [
    ../../modules/nixos/common.nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";

  image.modules.iso = [({config, ...}: {
    imports = [
      (modulesPath + "/installer/cd-dvd/iso-image.nix")
    ];
    disabledModules = [
      ./hardware-configuration.nix
    ];
    # sdImage.compressImage = false;
    system.build.image = config.system.build.isoImage;
  })];
}
