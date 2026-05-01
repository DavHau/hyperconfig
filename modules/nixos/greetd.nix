{ pkgs, lib, ... }:
{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = lib.concatStringsSep " " [
          "${pkgs.greetd.tuigreet}/bin/tuigreet"
          "--time"
          "--remember"
          "--remember-user-session"
          "--asterisks"
          "--cmd niri-session"
        ];
        user = "greeter";
      };
    };
  };

  # NixOS enables lightdm by default once xserver.enable = true; force it off
  # so greetd is the sole display manager.
  services.xserver.displayManager.lightdm.enable = lib.mkForce false;
}
