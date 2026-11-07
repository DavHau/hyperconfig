# Wi-Fi client for the Parasit / Parasit_5G networks. The password is a shared
# clan var, entered once:
#     clan vars generate <host> --generator wifi-parasit
# wpa_supplicant reads `ext:PW` at runtime from the `varname=value` secrets file.
{
  config,
  ...
}:
let
  gen = config.clan.core.vars.generators.wifi-parasit;
in
{
  clan.core.vars.generators.wifi-parasit = {
    share = true;
    prompts.password = {
      type = "hidden";
      persist = true;
      description = "password of the Parasit / Parasit_5G Wi-Fi";
    };
    files.password.deploy = false;
    files.secrets = {
      owner = "wpa_supplicant";
      group = "wpa_supplicant";
    };
    script = ''
      printf 'PW=%s\n' "$(cat "$prompts/password")" > "$out/secrets"
    '';
  };

  # wifi
  networking.wireless.enable = true;
  networking.wireless.secretsFile = gen.files.secrets.path;
  networking.wireless.networks.Parasit_5G.auth = "password=ext:PW";
  networking.wireless.networks.Parasit_5G.priority = 10;
  networking.wireless.networks.Parasit.auth = "password=ext:PW";
}
