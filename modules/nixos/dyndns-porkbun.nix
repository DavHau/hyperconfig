{config, lib, pkgs, ...}:
let
  cfg = config.services.porkbun;
in
{
  options = {
    services.porkbun.ipv4Entries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of A records to update";
      example = [ "example.com/A/subdomain" ];
    };
    services.porkbun.ipv6Entries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of AAAA records to update";
      example = [ "example.com/AAAA/subdomain" ];
    };
  };

  config = {
    clan.core.vars.generators.porkbun = {
      share = true;
      prompts.apikey.type = "hidden";
      prompts.apikey.persist = true;
      prompts.secretkey.type = "hidden";
      prompts.secretkey.persist = true;
    };
    systemd.timers.porkbun-dyndns = {
      description = "Update porkbun dynamic dns";
      wantedBy = [ "timers.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      timerConfig.OnCalendar = "*-*-* *:00:00";  # every hour
    };
    systemd.services.porkbun-dyndns = {
      description = "Update porkbun dynamic dns";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.curl
      ];
      serviceConfig.Type = "oneshot";
      script = lib.optionalString (cfg.ipv4Entries != []) ''
        ipv4=$(curl -4 --silent --fail ifconfig.co)
        for entry in ${toString cfg.ipv4Entries}; do
          curl "https://api.porkbun.com/api/json/v3/dns/editByNameType/''${entry}" -d "
            {
              \"apikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.apikey.path})\",
              \"secretapikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.secretkey.path})\",
              \"content\": \"$ipv4\"
            }
          "
        done
      ''
      + lib.optionalString (cfg.ipv6Entries != []) ''
        ipv6=$(curl -6 --silent --fail ifconfig.co)
        for entry in ${toString cfg.ipv6Entries}; do
          curl "https://api.porkbun.com/api/json/v3/dns/editByNameType/''${entry}" -d "
            {
              \"apikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.apikey.path})\",
              \"secretapikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.secretkey.path})\",
              \"content\": \"$ipv6\"
            }
          "
        done
      '';
    };
  };
}
