{ pkgs, lib, ... }: {
  imports = [
    ./vscode.nix
  ];

  # services
  services.dunst.enable = true;
  services.udiskie.enable = true;
  systemd.user.targets.tray = {
    Unit = {
      Description = "Home Manager System Tray";
      Requires = [ "graphical-session-pre.target" ];
    };
  };

  programs.fish.enable = true;


  programs.zoxide.enable = true;

}
