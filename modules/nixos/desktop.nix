# X11/libinput basics and session variables (terminal = ghostty) on Dave's
# desktops; the compositor is niri (./niri-spaces).
{ pkgs, lib, ... }:
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
  environment.sessionVariables.TERMINAL = "ghostty";
  environment.sessionVariables.TERM = "xterm-256color";

  # power management
  services.power-profiles-daemon.enable = lib.mkDefault true;
}
