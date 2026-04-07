{ config, pkgs, lib, ... }:
{
  home-manager.users.dave = {
    home.stateVersion = "25.11";
    programs.rbw.enable = true;
    imports = [
      ../home-manager/common.nix
      ../home-manager/htop
      ../home-manager/firefox.nix
      ../home-manager/niri.nix
      ../home-manager/fish-ai.nix
    ];
  };

  nix.settings.trusted-users = [ "dave" ];
}
