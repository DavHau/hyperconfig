{ lib, ... }:
{
  _class = "clan.service";
  manifest.name = "cctl";
  manifest.description = "cctl web dashboard for managing Claude Code sessions";
  manifest.categories = [ "Development" ];
  manifest.readme = "Web dashboard for managing Claude Code sessions via nginx reverse proxy with basic auth.";

  roles.server = {
    description = "Hosts the cctl web dashboard for managing Claude Code sessions.";

    interface = { lib, ... }: {
      options = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 4141;
          description = "Internal port cctl listens on.";
        };
        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          defaultText = "<instanceName>.<machineName>.<clan-domain>";
          description = "Nginx virtualHost domain for the cctl dashboard.";
        };
        user = lib.mkOption {
          type = lib.types.str;
          description = "User to run the cctl service as.";
        };
      };
    };

    perInstance =
      { settings, instanceName, machine, ... }:
      {
        nixosModule =
          { config, pkgs, inputs, ... }:
          let
            cctlPkg = inputs.cctl.packages.${pkgs.stdenv.hostPlatform.system}.default;
            domain =
              if settings.domain != null
              then settings.domain
              else "${instanceName}.${machine.name}.${config.clan.core.settings.domain}";
            credName = "cctl-${instanceName}-htpasswd";
            htpasswdPath = config.clan.core.vars.generators."cctl-${instanceName}".files.htpasswd.path;
          in
          {
            # Generate password + htpasswd for basic auth
            clan.core.vars.generators."cctl-${instanceName}" = {
              share = true;
              files.password.secret = true;
              files.htpasswd.secret = true;
              runtimeInputs = [
                pkgs.pwgen
                pkgs.apacheHttpd
              ];
              script = ''
                pwgen -s 32 1 > "$out/password"
                htpasswd -cb "$out/htpasswd" cctl "$(cat "$out/password")"
              '';
            };

            environment.systemPackages = [ cctlPkg ];

            # cctl systemd service
            systemd.services."cctl-${instanceName}" = {
              description = "cctl web dashboard (${instanceName})";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];
              path = [ pkgs.claude-code ];
              serviceConfig = {
                ExecStart = "${cctlPkg}/bin/cctl serve --port ${toString settings.port}";
                User = settings.user;
                Restart = "on-failure";
                RestartSec = 5;
              };
            };

            # Load htpasswd into nginx via systemd credentials
            systemd.services.nginx.serviceConfig.LoadCredential = [
              "${credName}:${htpasswdPath}"
            ];

            # Nginx reverse proxy with basic auth
            services.nginx.enable = true;
            services.nginx.virtualHosts.${domain} = {
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString settings.port}";
                proxyWebsockets = true;
              };
              basicAuthFile = "/run/credentials/nginx.service/${credName}";
            };
          };
      };
  };
}
