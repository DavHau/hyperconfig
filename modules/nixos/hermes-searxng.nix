# A private SearXNG metasearch instance, the web_search backend of the
# native hermes agents (./hermes-native). Loopback-only; the agents run on
# the host and dial 127.0.0.1 directly. Vendored from spaces 6d744780
# modules/nixos/searxng.nix, which serves microVM guests through slirp's
# host alias instead; a host runs one of the two
# (services.spaces-searxng.enable = false beside this one).
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hermes-searxng;
  # spaces' unit and state names, so a host switching over keeps its key.
  envFile = "/var/lib/spaces-searxng/env";
in
{
  options.services.hermes-searxng = {
    enable = lib.mkEnableOption "a loopback-only SearXNG for the native hermes agents" // {
      default = config.services.hermes-native.enable;
      defaultText = lib.literalExpression "config.services.hermes-native.enable";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8890;
      description = ''
        Host loopback port of the SearXNG HTTP server. The default stays
        clear of the other agent windows: llama-swap (8012), the simplex
        and dashboard backends (10000+uid, 20000+uid) and the public
        dashboard/simplex ports (22100-25099).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(config.services.spaces-searxng.enable or false);
        message = "services.hermes-searxng and spaces' services.spaces-searxng both run services.searx and its secret unit; set services.spaces-searxng.enable = false.";
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
          inherit (cfg) port;
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
      environment.SEARXNG_URL = lib.mkDefault "http://127.0.0.1:${toString cfg.port}";
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
    systemd.services.spaces-searxng-secret = {
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
        StateDirectory = "spaces-searxng";
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
