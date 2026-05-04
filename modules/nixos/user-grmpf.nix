{ config, pkgs, lib, ... }:
{
  users.users.grmpf = {
    isNormalUser = true;
    hashedPasswordFile = config.users.users.dave.hashedPasswordFile;
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf@grmpf-ThinkPad-T460p" ];
    extraGroups = [ "wheel" "networkmanager" "audio" "ledger" "plugdev" "dialout" ];
    # shell = pkgs.fish;
    autoSubUidGidRange = true;
  };
  users.extraUsers.grmpf.extraGroups = [ "libvirtd" "podman" "input" ];

  home-manager.users.grmpf = {
    home.stateVersion = "22.11";
    programs.rbw.enable = true;
    imports = [
      ../home-manager/common.nix
      ../home-manager/htop
      ../home-manager/firefox.nix
      ../home-manager/niri.nix
      ../home-manager/fish-ai.nix
    ];
  };

  nix.settings.trusted-users = [ "grmpf" ];
}
