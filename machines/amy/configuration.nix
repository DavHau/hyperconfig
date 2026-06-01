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
    ../../modules/nixos/llama-swap.nix
    ../../modules/nixos/bluetooth-resume-fix.nix
    ../../modules/nixos/fw-fanctrl.nix
    ./disko.nix
  ];

  virtualisation.vmVariant = {
    imports = [ ../../modules/nixos/user-dave.nix ];
    users.users.grmpf.hashedPasswordFile = lib.mkForce null;
    users.users.grmpf.hashedPassword = lib.mkForce null;
    users.users.grmpf.initialPassword = "grmpf";

    users.users.dave.hashedPasswordFile = lib.mkForce null;
    users.users.dave.hashedPassword = lib.mkForce null;
    users.users.dave.initialPassword = "dave";

    # virtualisation.qemu.options = [
    #   "-device virtio-vga-gl"
    #   "-display gtk,gl=on"
    # ];
    virtualisation.memorySize = 8192;

    # virtualisation.forwardPorts = [
    #   { from = "host"; host.port = 2222; guest.port = 22; }
    # ];
    services.openssh.enable = true;
    services.openssh.settings.PasswordAuthentication = lib.mkForce true;
    services.openssh.settings.KbdInteractiveAuthentication = lib.mkForce true;
    home-manager.backupFileExtension = "hm-backup";

    # VM (host captures Super) → use Alt as niri's mod-key.
    services.spaces.niri.modKey = "Alt";
  };

  # required by zfs
  networking.hostId = "5eb1bf28";

  # Disable USB autosuspend for Intel AX210 Bluetooth — prevents adapter
  # from powering down shortly after boot (firmware load race on new card).
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0032", ATTR{power/autosuspend_delay_ms}="-1"
  '';

  system.stateVersion = "19.03"; # Did you read the comment?
}
