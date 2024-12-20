{
  services.home-assistant = {
    enable = true;
    config = null;
    extraComponents = [
      # List of components required to complete the onboarding
      "default_config"
      "met"
      "esphome"
      "rpi_power"
      "radio_browser"
      "backup"

      "zha"
      "broadlink"
    ];
  };
  networking.firewall.allowedTCPPorts = [8123];
}
