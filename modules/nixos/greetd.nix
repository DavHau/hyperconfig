{ pkgs, lib, ... }:
{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = lib.concatStringsSep " " [
          "${pkgs.tuigreet}/bin/tuigreet"
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

  # Don't tear down the active session on `nixos-rebuild switch`. greetd only
  # needs to be running to authenticate the next login; restarting it kicks
  # tuigreet's child PAM session, which kills the user's compositor.
  systemd.services.greetd.restartIfChanged = false;
}
