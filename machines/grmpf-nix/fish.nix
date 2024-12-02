{config, pkgs, ...}: {
  users.defaultUserShell = config.home-manager.users.grmpf.programs.fish.package;
  programs.fish.enable = true;
  # programs.fish.shellInit =
  #   config.home-manager.users.grmpf.programs.fish.shellInit;
}
