{pkgs, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
  ];

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  services.printing.enable = true;

  networking.networkmanager.enable = true;
  services.resolved.enable = true;

  environment.systemPackages = with pkgs; [
    krita
    gimp
    inkscape
    firefox
    libreoffice
  ];
}
