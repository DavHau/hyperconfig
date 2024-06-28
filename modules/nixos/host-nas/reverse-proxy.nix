{lib, config, ...}: {
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  services.nginx.enable = true;
  services.nginx.virtualHosts."casa.bruch-bu.de" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://192.168.178.24:8123";
      proxyWebsockets = true; # needed if you need to use WebSocket
      extraConfig =
        # required when the server wants to use HTTP Authentication
        "proxy_pass_header Authorization;"
        ;
    };
  };
  services.nginx.virtualHosts."playa.bruch-bu.de" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://192.168.10.3:8123";
      proxyWebsockets = true; # needed if you need to use WebSocket
      extraConfig =
        # required when the server wants to use HTTP Authentication
        "proxy_pass_header Authorization;"
        ;
    };
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "info@davhau.com";
  };
}
