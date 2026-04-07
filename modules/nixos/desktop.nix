{ pkgs, ... }:
{
  # VIDEO
  services.xserver.videoDrivers = [ "modesetting" ];

  # X11
  services.libinput.enable = true;
  services.libinput.mouse.clickMethod = "clickfinger";
  services.xserver.enable = true;
  services.xserver.xkb.layout = "us";
  services.xserver.xkb.variant = "altgr-intl";
  services.xserver.xkb.options = "eurosign:e";

  # block middle click paste
  systemd.services.xmousepasteblock = {
    script = "${pkgs.xmousepasteblock}/bin/xmousepasteblock";
  };

  # session variables
  environment.sessionVariables.TERMINAL = "alacritty";
  environment.sessionVariables.TERM = "xterm-256color";

  # power management
  services.power-profiles-daemon.enable = true;
}
