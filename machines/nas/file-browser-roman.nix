{config, lib, pkgs, ...}:
let
  users = ["manu" "roman"];
  portFor = lib.listToAttrs (
    lib.imap0
      (idx: user: {name = user; value = 8500 + idx;})
      users
  );
  userModule = user: {
    services.nginx.enable = true;
    services.nginx.virtualHosts."daten.${user}.bruch-bu.de" = {
      forceSSL = true;
      enableACME = true;
      basicAuthFile = pkgs.writeText "filebrowser-auth" ''
        ${user}:${config.users.users.${user}.hashedPassword}
      '';
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString portFor.${user}}";
        proxyWebsockets = true;
        extraConfig = ''
          client_max_body_size 4G;
        '';
      };
    };
    systemd.services."filebrowser-${user}" = {
      description = "Filebrowser for user ${user}";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "automount.service"];
      wants = ["network-online.target"];
      serviceConfig = {
        User = config.users.users.${user}.name;
        Restart = "always";
      };
      path = [
        pkgs.getent
      ];
      # Start filebrowser without auth (auth done by nginx).
      script = ''
        cd ${config.users.users.${user}.home}
        ${pkgs.filebrowser}/bin/filebrowser --noauth --port ${toString portFor.${user}}
      '';
    };
  };
in
lib.mkMerge (
  map userModule users
)
