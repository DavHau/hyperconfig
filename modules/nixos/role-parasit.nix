{
  config,
  ...
}: {
  # wifi
  networking.wireless.enable = true;
  networking.wireless.networks.Parasit_5G.psk = "@PW@";
  networking.wireless.networks.Parasit_5G.priority = 10;
  networking.wireless.networks.Parasit.psk = "@PW@";
  networking.wireless.environmentFile = config.age.secrets.wifi-parasit.path;

  age.secrets = {
    wifi-parasit.file = ../../secrets/wifi-parasit.age;
  };
}
