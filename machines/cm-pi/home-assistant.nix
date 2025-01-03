{config, lib, ...}: {
  # allow access to zigbee antenna
  services.udev.extraRules = ''
    ENV{DEVNAME}=="/dev/ttyACM0", owner="hass"
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

      "zha"
      "broadlink"
    ];
    # These are the modules behind "default_config", excluded python-matter-server
    # TODO: fix cross compilation for python-matter-server
    extraPackages = python3Packages: with python3Packages; [
      aiodhcpwatcher
      aiodiscover
      aiohasupervisor
      async-upnp-client
      av
      bleak
      bleak-retry-connector
      bluetooth-adapters
      bluetooth-auto-recovery
      bluetooth-data-tools
      cached-ipaddress
      dbus-fast
      fnv-hash-fast
      go2rtc-client
      ha-ffmpeg
      habluetooth
      hass-nabucasa
      hassil
      home-assistant-frontend
      home-assistant-intents
      ifaddr
      mutagen
      numpy_1
      pillow
      psutil-home-assistant
      pymicro-vad
      pynacl
      pyserial
      pyspeex-noise
      # python-matter-server
      pyturbojpeg
      pyudev
      securetar
      sqlalchemy
      zeroconf
    ];
  };
  networking.firewall.allowedTCPPorts = [8123];
}
