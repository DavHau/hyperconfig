{pkgs, ...}: {
  imports = [
    ./pinentry.nix
  ];
  home-manager.users.grmpf.programs.rbw.enable = true;
}
