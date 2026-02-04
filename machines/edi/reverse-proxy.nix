{lib, config, ...}: {
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  services.nginx.enable = true;
  services.nginx.virtualHosts."bearhouse.davhau.com" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://cm-pi.d:8123";
      proxyWebsockets = true; # needed if you need to use WebSocket
      extraConfig =
        # required when the server wants to use HTTP Authentication
        "proxy_pass_header Authorization;"
        ;
    };
  };
  services.nginx.virtualHosts."nc.davhau.com" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://bam.d:82";
      proxyWebsockets = true; # needed if you need to use WebSocket
      extraConfig =
        # required when the server wants to use HTTP Authentication
        "proxy_pass_header Authorization;"
        ;
    };
  };
  services.nginx.virtualHosts."tasks.davhau.com" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://bam.d:8083";
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
