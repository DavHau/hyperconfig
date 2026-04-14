{ pkgs, inputs, ... }:
{
  imports = [
    inputs.noctalia.homeModules.default
  ];

  xdg.configFile."niri/config.kdl".source = ../nixos/niri-config.kdl;

  services.network-manager-applet.enable = true;

  services.swayidle = {
    enable = true;
    events = [
      { event = "before-sleep"; command = "${pkgs.swaylock}/bin/swaylock -f -c 000000"; }
    ];
    timeouts = [
      { timeout = 300; command = "${pkgs.swaylock}/bin/swaylock -f -c 000000"; }
      { timeout = 600; command = "niri msg action power-off-monitors"; }
    ];
  };

  programs.noctalia-shell = {
    enable = true;
    settings.bar.widgets = {
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
      ];
      right = [
        { id = "Tray"; }
        { id = "NotificationHistory"; }
        { id = "Battery"; }
        { id = "Volume"; }
        { id = "Brightness"; }
        { id = "ControlCenter"; }
      ];
    };
  };

  xdg.configFile."noctalia/settings.json".force = true;
}
