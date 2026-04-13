{pkgs, inputs, ...}: {
  imports = [
    inputs.nixos-hardware.nixosModules.framework-12-13th-gen-intel
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/sbox.nix
    ./output-formats.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  boot.loader.systemd-boot.enable = true;
  hardware.enableAllHardware = true;

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  services.printing.enable = true;

  networking.networkmanager.enable = true;
  services.resolved.enable = true;

  environment.systemPackages = with pkgs; [
    firefox
    gimp
    inkscape
    krita
    libreoffice
    telegram-desktop
    maliit-keyboard
    xournalpp
    rnote
  ];
}
