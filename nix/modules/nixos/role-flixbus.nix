{
  config,
  ...
}: {
  # wifi
  networking.wireless.enable = true;
  networking.wireless.networks.Flixbus.psk = "hallohallo12345";
}
