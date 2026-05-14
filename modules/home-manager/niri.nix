{ pkgs, inputs, ... }:
let
  settings = {
    bar.widgets = {
      left = [
        { id = "Launcher"; }
        { id = "Clock"; }
        {
          id = "SystemMonitor";
          compactMode = false;
          showNetworkStats = true;
        }
        { id = "ActiveWindow"; }
        { id = "MediaMini"; }
      ];
      center = [
        { id = "Workspace"; }
        { id = "plugin:opencrow-chat"; }
      ];
      right = [
        { id = "Tray"; }
        { id = "Network"; }
        { id = "Bluetooth"; }
        { id = "NotificationHistory"; }
        {
          id = "Battery";
          alwaysShowPercentage = true;
        }
        { id = "PowerProfile"; }
        { id = "Volume"; }
        { id = "Brightness"; }
        { id = "ControlCenter"; }
      ];
    };
  };
  settingsFile = (pkgs.formats.json { }).generate "noctalia-settings.json" settings;
  # Wrap noctalia-shell via lassulus/wrappers: point it at a store-path
  # settings.json via NOCTALIA_SETTINGS_FILE (honored by Commons/Settings.qml).
  # pkgs.noctalia-shell carries distro's plugins-autoload patch via the
  # `distro.overlays.noctalia` overlay wired into nixpkgs.
  noctalia-shell = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = pkgs.noctalia-shell;
    env.NOCTALIA_SETTINGS_FILE = settingsFile;
  };
in
{
  services.swayidle = {
    enable = true;
    events = {
      "before-sleep" = "${pkgs.swaylock}/bin/swaylock -f -c 000000";
    };
    timeouts = [
      { timeout = 300; command = "${pkgs.swaylock}/bin/swaylock -f -c 000000"; }
      { timeout = 600; command = "niri msg action power-off-monitors"; }
    ];
  };

  home.packages = [ noctalia-shell ];
}
