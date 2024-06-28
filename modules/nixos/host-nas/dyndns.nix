{config, lib, pkgs, ...}: {
  systemd.timers.porkbun-dyndns = {
    description = "Update porkbun dynamic dns";
    wantedBy = [ "timers.target" ];
    after = [ "network-online.target" ];
    timerConfig.OnCalendar = "*-*-* *:00:00";  # every hour
  };
  systemd.services.porkbun-dyndns = {
    description = "Update porkbun dynamic dns";
    wantedBy = [ "multi-user.target" ];
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
          \"apikey\": \"pk1_b8b994f5a46f51c39a22cfde517742a03b2531d03055e2cc9d791aabd0d701ed\",
          \"secretapikey\": \"sk1_bee6544eb489d8a8815e84eb761901a7eaf302a3cc93a1db1f637f002965cdbc\",
          \"content\": \"$ipv4\"
        }
      "
      curl https://porkbun.com/api/json/v3/dns/editByNameType/bruch-bu.de/AAAA/casa -d "
        {
          \"apikey\": \"pk1_b8b994f5a46f51c39a22cfde517742a03b2531d03055e2cc9d791aabd0d701ed\",
          \"secretapikey\": \"sk1_bee6544eb489d8a8815e84eb761901a7eaf302a3cc93a1db1f637f002965cdbc\",
          \"content\": \"$ipv6\"
        }
      "
    '';
  };
}
