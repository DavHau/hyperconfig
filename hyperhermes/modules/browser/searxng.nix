# A private SearXNG metasearch instance on loopback, the web_search
# backend of the agents.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  port = 8890;
  envFile = "/var/lib/hermes-searxng/env";
in
{
  # web_search's backend, per agent (./options.nix says why not host-wide).
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          config = lib.mkIf (cfg.browser.enable && config.browser.enable) {
            environment.SEARXNG_URL = lib.mkDefault "http://127.0.0.1:${toString port}";
            settings.web.search_backend = lib.mkDefault "searxng";
          };
        }
      )
    );
  };

  config = lib.mkIf cfg.browser.enable {
    services.searx = {
      enable = true;
      # nixpkgs' searxng (or browser.searxng.source) with our patches.
      package = import ./searxng-package.nix {
        inherit pkgs;
        inherit (cfg.browser.searxng) source;
      };
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
          ++
            map
              (name: {
                inherit name;
                disabled = false;
                inactive = false;
              })
              [
                "startpage"
                "mojeek"
              ]
          # Not loaded while general.contact_url is unset (below).
          ++
            map
              (name: {
                inherit name;
                inactive = true;
              })
              [
                "wikipedia"
                "wikidata"
                "openstreetmap"
              ];
        # No general.contact_url on purpose: upstream master (since
        # 38929d14, 2026-11-12, newer than the pin; the nightly bump takes
        # it) puts it into the User-Agent of Wikipedia, Wikidata and OSM
        # (Wikimedia's User-Agent policy) and logs an error on every query
        # of theirs without one, and no contact in this repo is
        # neutral (the agents' mail domain and the instance URL both name
        # their owner). Those three engines are off instead (engine list
        # above, `inactive`: not even loaded, so no error per query); they
        # gave agents no relevant results anyway (2026-11).
        # To turn them on: set general.contact_url to a role address that
        # identifies no one (or SEARXNG_CONTACT_URL in environmentFile)
        # and drop their `inactive` entries.
      };
      # Bot detection reads limiter.toml even with the limiter off, and
      # warns when it is missing. The file only has to exist (the module
      # writes none for empty settings), so it restates one default.
      limiterSettings.botdetection.ipv4_prefix = 32;
    };

    # SearXNG exits at startup while server.secret_key is the upstream
    # default (webapp.py, the "ultrasecretkey" check). The key only signs
    # web-UI session cookies, so it is generated, never managed.
    #
    # An own unit, not a preStart on searx-init: systemd applies
    # EnvironmentFile= to every Exec* process, and the upstream module
    # passes the path without the "-" prefix, so on first boot searx-init
    # would fail before its own pre-command could create the file.
    # nixpkgs' unit is sandboxed already (PrivateUsers, @system-service
    # minus @privileged/@resources, ProtectSystem=strict); it leaves the
    # capability bounding set unset (null: full). A web app needs none. Network reach is
    # the host's call (som: hyper.mullvadEgress.tunnelOnly).
    systemd.services.searx.serviceConfig = {
      CapabilityBoundingSet = lib.mkForce "";
      AmbientCapabilities = "";
    };

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
