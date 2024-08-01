{config, lib, pkgs, ...}: {

  services.nginx.enable = true;
  services.nginx.virtualHosts."daten.bruch-bu.de" = {
    forceSSL = true;
    enableACME = true;
    basicAuthFile = pkgs.writeText "filebrowser-auth" ''
      roman:${config.users.users.roman.hashedPassword}
    '';
    locations."/" = {
      proxyPass = "http://127.0.0.1:8567";
      proxyWebsockets = true;
    };
  };
  systemd.services.filebrowser = {
    description = "Filebrowser";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig.User = config.users.users.roman.name;
    path = [
      pkgs.getent
    ];
    # Start filebrowser without auth (auth done by nginx).
    script = ''
      cd ${config.users.users.roman.home}
      ${pkgs.filebrowser}/bin/filebrowser --noauth --port 8567
    '';
  };
}
