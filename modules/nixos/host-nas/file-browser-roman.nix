{config, lib, pkgs, ...}: {

  # manage password via clan secrets
  clan.core.facts.services.filebrowser-roman = {
    secret.filebrowser-roman = {};
    generator.prompt = "Type in the password for the filebrowser user roman";
    generator.script = ''
      ${pkgs.apacheHttpd}/bin/htpasswd -5cb $secrets/filebrowser-roman roman $prompt_value
    '';
  };
  sops.secrets."${config.clan.core.machineName}-filebrowser-roman".owner = "nginx";

  services.nginx.enable = true;
  services.nginx.virtualHosts."daten.bruch-bu.de" = {
    forceSSL = true;
    enableACME = true;
    basicAuthFile = config.clan.core.facts.services.filebrowser-roman.secret.filebrowser-roman.path;
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
