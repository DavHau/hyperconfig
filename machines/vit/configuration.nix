{ config, pkgs, lib, inputs, self, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.asus-zephyrus-gu605cw
    ../../modules/nixos/laptop-dave.nix
    ../../modules/nixos/user-dave.nix
    ./disko.nix
  ];

  # Enable all hardware support
  hardware.enableAllHardware = true;

  # VM settings
  virtualisation.vmVariant = {
    users.users.dave.hashedPasswordFile = lib.mkForce null;
    users.users.dave.hashedPassword = lib.mkForce "$6$4PW3Q8YUR5.aep1m$fbCWXV2Lfuo53gE0Pz7BZo7V4AgRq6O6dWZ47vnzzgZsUuh7q389xzlSW9ku0SGP2kfMQhJ3BVasp01/NplRx/";  # dave

    virtualisation.qemu.options = [
      "-device virtio-vga-gl"
      "-display gtk,gl=on"
    ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;

    # Enable SSH and forward port for debugging
    virtualisation.forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
    ];
    services.openssh.enable = true;
    home-manager.backupFileExtension = "hm-backup";

    # Use Alt as Mod key in VM (host captures Super)
    home-manager.users.dave.xdg.configFile."niri/config.kdl".source = lib.mkForce (pkgs.runCommand "niri-vm-config.kdl" {} ''
      cp ${../../modules/nixos/niri-config.kdl} $out
      chmod +w $out
      sed -i '/^input {/a\    mod-key "Alt"' $out
    '');
  };

  system.stateVersion = "25.11";

  security.tpm2.enable = true;
}
