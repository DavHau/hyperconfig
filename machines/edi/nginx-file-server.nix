{lib, config, ...}: {
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  services.nginx.enable = true;
  services.nginx.virtualHosts."files.davhau.com" = {
    forceSSL = true;
    enableACME = true;
    # locations."/".root = "/var/www/files";
    root = "/var/www/files";
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "info@davhau.com";
  };
}
