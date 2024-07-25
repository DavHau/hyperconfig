{config, lib, pkgs, ...}: {
  clan.core.vars.generators.porkbun = {
    files.apikey.secret = true;
    files.secretkey.secret = true;
    prompts.apikey.type = "hidden";
    prompts.secretkey.type = "hidden";
    script = ''
      cat $prompts/apikey > $out/apikey
      cat $prompts/secretkey > $out/secretkey
    '';
  };
  # clan.core.facts.services.porkbun-apikey = {
  #   secret.apikey = {};
  #   generator.prompt = "Enter your porkbun apikey";
  #   generator.script = ''
  #     echo $prompt_value > $secrets/apikey
  #   '';
  # };
  # clan.core.facts.services.porkbun-secretkey = {
  #   secret.secretkey = {};
  #   generator.prompt = "Enter your porkbun secretkey";
  #   generator.script = ''
  #     echo $prompt_value > $secrets/secretkey
  #   '';
  # };
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
    script = ''
      set -e
      ipv4=$(curl -4 --silent --fail ifconfig.co)
      ipv6=$(curl -6 --silent --fail ifconfig.co)
      curl https://porkbun.com/api/json/v3/dns/editByNameType/bruch-bu.de/A/casa -d "
        {
          \"apikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.apikey.path})\",
          \"secretapikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.secretkey.path})\",
          \"content\": \"$ipv4\"
        }
      "
      curl https://porkbun.com/api/json/v3/dns/editByNameType/bruch-bu.de/AAAA/casa -d "
        {
          \"apikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.apikey.path})\",
          \"secretapikey\": \"$(cat ${config.clan.core.vars.generators.porkbun.files.secretkey.path})\",
          \"content\": \"$ipv6\"
        }
      "
    '';
    # script = ''
    #   set -e
    #   ipv4=$(curl -4 --silent --fail ifconfig.co)
    #   ipv6=$(curl -6 --silent --fail ifconfig.co)
    #   curl https://porkbun.com/api/json/v3/dns/editByNameType/bruch-bu.de/A/casa -d "
    #     {
    #       \"apikey\": \"$(cat ${config.clan.core.facts.services.porkbun-apikey.secret.apikey.path})\",
    #       \"secretapikey\": \"$(cat ${config.clan.core.facts.services.porkbun-secretkey.secret.secretkey.path})\",
    #       \"content\": \"$ipv4\"
    #     }
    #   "
    #   curl https://porkbun.com/api/json/v3/dns/editByNameType/bruch-bu.de/AAAA/casa -d "
    #     {
    #       \"apikey\": \"$(cat ${config.clan.core.facts.services.porkbun-apikey.secret.apikey.path})\",
    #       \"secretapikey\": \"$(cat ${config.clan.core.facts.services.porkbun-secretkey.secret.secretkey.path})\",
    #       \"content\": \"$ipv6\"
    #     }
    #   "
    # '';
  };
}
