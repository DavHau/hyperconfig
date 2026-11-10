{config, lib, pkgs, ...}: {
  # allow access to zigbee antenna
  services.udev.extraRules = ''
    ENV{DEVNAME}=="/dev/ttyACM0", OWNER="hass"
  '';
  services.home-assistant = {
    enable = true;
    config = null;
    # Login via the clan's pocket-id (modules/clan/oidc, public client
    # `home-assistant`). With config = null the YAML is hand-managed on the
    # host; the component only gets symlinked. configuration.yaml needs:
    #   auth_oidc:
    #     client_id: home-assistant
    #     discovery_url: https://id.davhau.com/.well-known/openid-configuration
    #     display_name: DavHau
    #     features:
    #       automatic_user_linking: true   # OIDC `dave` -> existing HA user `dave`
    # Reverse proxy (edi's nginx, bearhouse.davhau.com): since HA 2026.10 the
    # http settings live in /var/lib/hass/.storage/http (YAML `http:` is
    # ignored after its one-time migration). data.stable needs
    #   use_x_forwarded_for = true, trusted_proxies = [ <edi.d's ygg address> ]
    # or every proxied request gets 400.
    customComponents = [ pkgs.home-assistant-custom-components.auth_oidc ];
    extraComponents = [
      # List of components required to complete the onboarding
      # "default_config"
      "met"
      "esphome"
      "rpi_power"
      "radio_browser"
      "backup"
      # "mobile_app"

      "zha"
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
      cronsim
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
      numpy
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
