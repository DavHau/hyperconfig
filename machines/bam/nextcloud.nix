# Nextcloud behind nc.davhau.com (edi's reverse proxy). Login also via the
# clan's pocket-id (modules/clan/oidc, client `nextcloud`): user_oidc with
# unique-uid off and the uid mapped from preferred_username, so an OIDC
# login lands on the existing local account of the same name (soft
# auto-provisioning, upstream default). Password login stays enabled.
#
# nc.davhau.com terminates TLS on edi and proxies plain http to bam.d:82;
# user_oidc refuses to start a login on what looks like http, so requests
# arriving from edi (its yggdrasil address, a public clan var) are treated
# as https. Direct http://bam.d:82 use is unaffected.
{config, lib, pkgs, inputs, ...}:
let
  oidc = config.hyper.oidc.clients.nextcloud;
  occ = lib.getExe config.services.nextcloud.occ;
  ediYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "edi";
    generator = "yggdrasil";
    file = "address";
  };
in {
  services.nextcloud = {
    enable = true;
    # Nextcloud upgrades one major version at a time: bump this by one
    # and deploy before the next.
    package = pkgs.nextcloud33;
    hostName = "nextcloud";
    config.adminpassFile = config.clan.core.vars.generators.nextcloud.files.admin-password.path;
    config.dbtype = "pgsql";
    database.createLocally = true;
    extraAppsEnable = true;
    extraApps = {
      inherit (config.services.nextcloud.package.packages.apps)
        deck
        tasks
        user_oidc
        ;
    };
    settings = {
      trusted_domains = [ "bam.d" "nc.davhau.com" ];
      trusted_proxies = [ ediYgg ];
      overwritecondaddr = "^${lib.escapeRegex ediYgg}$";
      overwriteprotocol = "https";
      overwritehost = "nc.davhau.com";
    };
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

  # The provider lives in the database; `user_oidc:provider` is an upsert,
  # so re-running it on every activation keeps it declarative. The secret
  # is root-owned and rides in through LoadCredential (%d = its directory).
  systemd.services.nextcloud-oidc-provider = {
    description = "Register the clan's pocket-id as Nextcloud login provider";
    after = [ "nextcloud-setup.service" ];
    requires = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ config.hyper.oidc.issuer oidc.secretFile ];
    serviceConfig = {
      Type = "oneshot";
      User = "nextcloud";
      LoadCredential = [ "oidc_client_secret:${oidc.secretFile}" ];
      ExecCondition = "${occ} status --exit-code";
      ExecStart = lib.escapeShellArgs [
        occ "user_oidc:provider" "davhau"
        "--clientid=${oidc.clientId}"
        "--clientsecret-file=%d/oidc_client_secret"
        "--discoveryuri=${config.hyper.oidc.issuer}/.well-known/openid-configuration"
        "--scope=openid email profile"
        "--unique-uid=0"
        "--mapping-uid=preferred_username"
        "--mapping-email=email"
        "--mapping-display-name=name"
      ];
    };
  };

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
