{pkgs, ...}: {
  programs.niri.enable = true;
  programs.waybar.enable = true;

  environment.systemPackages = with pkgs; [
    fuzzel
    mako
    swayidle
    swaylock
    xwayland-satellite
  ];

  environment.variables = {
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    CLUTTER_BACKEND = "wayland";
    ECORE_EVAS_ENGINE = "wayland_egl";
    ELM_ENGINE = "wayland_egl";
    GDK_BACKEND = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
    NIXOS_OZONE_WL = "1";
    QT_QPA_PLATFORM = "wayland-egl";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
    QT_WAYLAND_FORCE_DPI = "physical";
    SDL_VIDEODRIVER = "wayland";
    XDG_SESSION_TYPE = "wayland";
  };

  security.pam.services.swaylock = {};
  security.polkit.enable = true;
}
