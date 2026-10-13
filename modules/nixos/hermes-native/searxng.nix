# A private SearXNG metasearch instance on loopback, the web_search
# backend of the agents.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hermes-native;
  port = 8890;
  envFile = "/var/lib/hermes-searxng/env";
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(config.services.spaces-searxng.enable or false);
        message = "services.hermes-native and spaces' services.spaces-searxng both run services.searx; set services.spaces-searxng.enable = false.";
      }
    ];

    services.searx = {
      enable = true;
      # The key rides the SEARXNG_SECRET env var, never the settings:
      # the rendered settings.yml lands in the world-readable store.
      environmentFile = envFile;
      # Built-in HTTP server, not uwsgi: few loopback consumers. It logs
      # queries to the journal; machine-local, accepted.
      settings = {
        server = {
          bind_address = "127.0.0.1";
          inherit port;
        };
        # hermes speaks only format=json. Stock SearXNG answers 403 for
        # a format that is not listed here.
        search.formats = [
          "html"
          "json"
        ];
      };
    };

    # Env and settings stay operator-overridable.
    services.hermes-native = {
      environment.SEARXNG_URL = lib.mkDefault "http://127.0.0.1:${toString port}";
      settings.web.search_backend = lib.mkDefault "searxng";
    };

    # SearXNG exits at startup while server.secret_key is the upstream
    # default (webapp.py, the "ultrasecretkey" check). The key only signs
    # web-UI session cookies, so it is generated, never managed.
    #
    # An own unit, not a preStart on searx-init: systemd applies
    # EnvironmentFile= to every Exec* process, and the upstream module
    # passes the path without the "-" prefix, so on first boot searx-init
    # would fail before its own pre-command could create the file.
    systemd.services.hermes-searxng-secret = {
      description = "Generate the SearXNG secret key";
      before = [
        "searx-init.service"
        "searx.service"
      ];
      requiredBy = [
        "searx-init.service"
        "searx.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "hermes-searxng";
      };
      script = ''
        if [ ! -e ${envFile} ]; then
          (
            umask 077
            printf 'SEARXNG_SECRET=%s\n' \
              "$(od -vAn -N32 -tx1 /dev/urandom | tr -d ' \n')" > ${envFile}
          )
        fi
      '';
    };
  };
}
