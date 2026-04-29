{ config, pkgs, lib, inputs, self, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
    # inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    # inputs.nixos-hardware.nixosModules.lenovo-yoga-7-14ARH7-amdgpu
    # inputs.nixos-hardware.nixosModules.tuxedo-pulse-14-gen3
    ../../modules/nixos/laptop-dave.nix
    ../../modules/nixos/user-grmpf.nix
    ../../modules/nixos/amdgpu.nix
    ./disko.nix
  ];

  virtualisation.vmVariant = {
    users.users.grmpf.hashedPasswordFile = lib.mkForce null;
    users.users.grmpf.hashedPassword = lib.mkForce null;
    users.users.grmpf.initialPassword = "grmpf";

    users.users.dave.hashedPasswordFile = lib.mkForce null;
    users.users.dave.hashedPassword = lib.mkForce null;
    users.users.dave.initialPassword = "dave";

    virtualisation.qemu.options = [
      "-device virtio-vga-gl"
      "-display gtk,gl=on"
    ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;

    virtualisation.forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
    ];
    services.openssh.enable = true;
    home-manager.backupFileExtension = "hm-backup";

    # Use Alt as Mod key in VM (host captures Super)
    niri.inputSettings.mod-key = "Alt";
  };

  # required by zfs
  networking.hostId = "5eb1bf28";

  boot.kernelPackages = pkgs.linuxPackages_6_19;

  system.stateVersion = "19.03"; # Did you read the comment?
}
