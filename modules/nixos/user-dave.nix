{ config, pkgs, lib, ... }:
{
  home-manager.users.dave = {
    home.stateVersion = "25.11";
    programs.rbw.enable = true;
    imports = [
      ../home-manager/common.nix
      ../home-manager/htop
      ../home-manager/firefox.nix
      # See ../user-grmpf.nix for why this is commented out (distro now owns
      # the noctalia launch; the wrapper would race it).
      # ../home-manager/niri.nix
      ../home-manager/fish-ai.nix
    ];
  };

  nix.settings.trusted-users = [ "dave" ];
}
