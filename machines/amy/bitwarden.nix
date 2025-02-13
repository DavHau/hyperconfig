{pkgs, ...}: {
  imports = [
    ./pinentry.nix
  ];
  home-manager.users.grmpf.programs.rbw.enable = true;
  environment.systemPackages = [
    # provides the executable `bw`
    pkgs.bitwarden-cli
  ];
}
