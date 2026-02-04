{config, pkgs, ...}: {
  services.nextcloud = {
    enable = true;
    hostName = "nextcloud";
    config.adminpassFile = config.clan.core.vars.generators.nextcloud.files.admin-password.path;
    config.dbtype = "pgsql";
    database.createLocally = true;
    extraAppsEnable = true;
    extraApps = {
      inherit (config.services.nextcloud.package.packages.apps)
        deck
        tasks
        ;
    };
    settings.trusted_domains = [ "bam.d" "nc.davhau.com" ];
  };

  services.nginx.virtualHosts.${config.services.nextcloud.hostName}.listen = [
    {
      addr = "0.0.0.0";
      port = 82;
    }
    {
      addr = "[::]";
      port = 82;
    }
  ];

  clan.core.vars.generators.nextcloud = {
    files.admin-password.secret = true;
    runtimeInputs = [
      pkgs.xkcdpass
    ];

    script =''
      xkcdpass --numwords 4 --delimiter - --count 1 | tr -d "\n" > "$out"/admin-password
    '';
  };

  networking.firewall.interfaces.ygg.allowedTCPPorts = [ 80 82 ];
}
