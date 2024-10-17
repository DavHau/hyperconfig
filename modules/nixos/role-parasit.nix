{
  config,
  pkgs,
  ...
}:
let
  secretFile = pkgs.runCommand "wifi-parasit" {} ''
    echo PW:"$(cat ${config.sops.secrets.wifi-parasit.path})" > $out
  '';
in
{
  # wifi
  networking.wireless.enable = true;
  networking.wireless.secretsFile = secretFile;
  networking.wireless.networks.Parasit_5G.auth = "password=ext:PW";
  networking.wireless.networks.Parasit_5G.priority = 10;
  networking.wireless.networks.Parasit.auth = "password=ext:PW";
}
