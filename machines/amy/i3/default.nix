{
  config,
  lib,
  pkgs,
  ...
}: {
  # services.xserver.displayManager.defaultSession = "none+i3";
  # services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.xterm.enable = false;
  services.xserver.windowManager.i3 = {
    enable = true;
    configFile = "${./i3_config}";
    extraPackages = with pkgs; [
      dmenu #application launcher most people use
      i3status # gives you the default i3 status bar
      i3lock #default i3 screen locker
      i3blocks #if you are planning on using i3blocks over i3status
      config.home-manager.users.grmpf.programs.i3status-rust.package
    ];
  };

  environment.pathsToLink = [
    # "/share/nix-direnv"
    "/libexec" # i3wm
  ];

  home-manager.users.grmpf = {
    # xsession.enable = true;
    # xsession.windowManager.i3 = {
    #   enable = true;
    # };

    programs.i3status-rust.enable = true;
    programs.i3status-rust.bars.blabla.blocks =
      builtins.fromTOML (builtins.readFile ./blocks.toml);
  };

  # services.xserver.windowManager.i3.config = {
  #   bars.i3blocks-rust.command =
  #     config.home-manager.users.grmpf.programs.i3status-rust.package;
  # };
}
