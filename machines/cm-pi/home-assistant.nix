{config, lib, pkgs, ...}: {
  # allow access to zigbee antenna
  services.udev.extraRules = ''
    ENV{DEVNAME}=="/dev/ttyACM0", OWNER="hass"
  '';
  services.home-assistant = {
    enable = true;
    config = null;
    extraComponents = [
      # List of components required to complete the onboarding
      # "default_config"
      "met"
      "esphome"
      "rpi_power"
      "radio_browser"
      "backup"
      "mobile_app"

      "zha"
    ];
  };
  networking.firewall.allowedTCPPorts = [8123];
}
