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
          # Loopback-only; a limiter would need Valkey.
          limiter = false;
        };
        # hermes speaks only format=json. Stock SearXNG answers 403 for
        # a format that is not listed here.
        search.formats = [
          "html"
          "json"
        ];
        # Merged by name into the stock engine list. hermes queries the
        # general category; arxiv, github and stackoverflow answer in
        # their own (science, it) or by bang (!arx, !gh, !st). A failing
        # engine is suspended by SearXNG itself, so keyless scrapers that
        # sometimes hit a CAPTCHA or a 429 stay in the list. No result
        # cache: the instance is shared, and a cache would let one agent
        # learn another's queries.
        engines =
          map
            (name: {
              inherit name;
              disabled = false;
            })
            [
              "google"
              "bing"
              "qwant"
              "yahoo"
              "duckduckgo"
              "brave"
              "arxiv"
              "github"
              "stackoverflow"
            ]
          # Stock-inactive engines are not even loaded.
          ++ map
            (name: {
              inherit name;
              disabled = false;
              inactive = false;
            })
            [
              "startpage"
              "mojeek"
            ];
      };
      # Bot detection reads limiter.toml even with the limiter off, and
      # warns when it is missing. The file only has to exist (the module
      # writes none for empty settings), so it restates one default.
      limiterSettings.botdetection.ipv4_prefix = 32;
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
