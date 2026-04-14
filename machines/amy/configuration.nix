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
    users.users.grmpf.hashedPassword = lib.mkForce "$6$4PW3Q8YUR5.aep1m$fbCWXV2Lfuo53gE0Pz7BZo7V4AgRq6O6dWZ47vnzzgZsUuh7q389xzlSW9ku0SGP2kfMQhJ3BVasp01/NplRx/";  # grmpf

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
    home-manager.users.grmpf.xdg.configFile."niri/config.kdl".source = lib.mkForce (pkgs.runCommand "niri-vm-config.kdl" {} ''
      cp ${../../modules/nixos/niri-config.kdl} $out
      chmod +w $out
      sed -i '/^input {/a\    mod-key "Alt"' $out
    '');
  };

  # required by zfs
  networking.hostId = "5eb1bf28";

  system.stateVersion = "19.03"; # Did you read the comment?
}
