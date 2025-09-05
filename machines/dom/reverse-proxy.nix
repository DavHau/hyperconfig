{lib, config, pkgs, ...}: {
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  clan.core.vars.generators.bauru = {
    files.nginx-apikey.secret = true;
    files.nginx-apikey.owner = "nginx";
    runtimeInputs = [pkgs.pwgen];
    script = ''
      pw=$(pwgen -s 32 1)
      echo "set \$valid_api_key \"$pw\";" > $out/nginx-apikey
    '';
  };
  services.nginx.enable = true;
  services.nginx.virtualHosts."bauru.davhau.com" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://localhost:9944";
      proxyWebsockets = true; # needed if you need to use WebSocket
      extraConfig = ''
        # required when the server wants to use HTTP Authentication
        proxy_pass_header Authorization;

        # load the secret API key from the generated file
        include ${config.clan.core.vars.generators.bauru.files.nginx-apikey.path};

        # Extract the apikey parameter from the query string
        if ($arg_apikey = "") {
            return 401 "API key required";
        }

        # Check if the provided API key matches the valid one
        if ($arg_apikey != $valid_api_key) {
            return 403 "Invalid API key";
        }

      '';
    };
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "info@davhau.com";
  };
}
