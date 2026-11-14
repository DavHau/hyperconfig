# Home-manager profile and nix trust for the `dave` user on Dave's
# desktops (amy, som, vit via ./dave.nix); amy's desktop user is grmpf
# (./user-grmpf.nix).
{ config, pkgs, lib, ... }:
{
  home-manager.users.dave = {
    home.stateVersion = "25.11";
    programs.rbw.enable = true;
    imports = [
      ../home-manager/common.nix
      ../home-manager/htop
      ../home-manager/firefox.nix
      ../home-manager/fish-ai.nix
    ];
  };

  nix.settings.trusted-users = [ "dave" ];
}
