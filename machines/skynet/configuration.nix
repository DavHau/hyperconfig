{lib, config, pkgs, inputs, ...}: {
  imports = [
    ./hardware.nix
    ./disko.nix
    inputs.disko.nixosModules.default
    inputs.srvos.nixosModules.server
    ./localai.nix
  ];

  boot.loader.grub.devices = ["/dev/sda"];
  boot.loader.grub.efiSupport = true;

  nixpkgs.hostPlatform = "x86_64-linux";
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  # CUDA
  nixpkgs.config.allowUnfreePredicate = pkg:
    lib.hasPrefix "nvidia-x11" (lib.getName pkg)
    || lib.hasPrefix "nvidia-settings" (lib.getName pkg)
    || lib.hasPrefix "cudatoolkit" (lib.getName pkg)
    || lib.hasPrefix "cuda_cudart" (lib.getName pkg)
    || lib.hasPrefix "cuda_nvcc" (lib.getName pkg)
    || lib.hasPrefix "libcublas" (lib.getName pkg);
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia.modesetting.enable = true;
  hardware.nvidia.nvidiaSettings = true;

  networking.useDHCP = true;

  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "af415e486f4514ce"
  ];

  users.users = {
    # root
    root = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
      ];
    };
  };
}
