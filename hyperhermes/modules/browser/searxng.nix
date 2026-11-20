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
  rp = cfg.browser.residentialProxy;
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
    assertions = [
      {
        assertion = rp.searxngEngines == [ ] || rp.url != null;
        message = "services.hyperhermes.browser.residentialProxy.searxngEngines needs residentialProxy.url.";
      }
    ];
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
        # engine is suspended by SearXNG itself. No result cache: the
        # instance is shared, and a cache would let one agent learn
        # another's queries.
        #
        # General web search is DuckDuckGo and Google's CSE endpoint
        # (stock-enabled), plus Mojeek where the host routes it through
        # its residential proxy (browser.residentialProxy.searxngEngines:
        # those go through it). Measured from som, 2026-11: over the
        # shared Mullvad exit DDG answers CAPTCHAs, the CSE 429 and Mojeek
        # 403; through the proxy DDG and the CSE answer on topic, Mojeek
        # mostly too (some exits 403 it as well).
        # Every engine appears once in this list (one entry per name).
        engines =
          map
            (name: {
              inherit name;
              disabled = false;
            })
            (
              lib.subtractLists rp.searxngEngines [
                "duckduckgo"
                "google cse"
                "arxiv"
                "github"
                "stackoverflow"
              ]
            )
          # Off: they answer, but with junk or nothing (som, 2026-11, the
          # same from the Mullvad exit and through the residential proxy):
          #   bing    results unrelated to the query, a different set on
          #           every request, whatever market, language or TLS
          #           target (searxng#4964, #6944): it filled the top 5
          #           with Microsoft Rewards and Outlook pages
          #   yahoo   Bing's index; junk over Mullvad, timeouts and empty
          #           pages through the proxy
          #   brave   429 over Mullvad; through the proxy every result
          #           URL is a cloaked /go/v1/<hash> link (searxng#6967)
          #   mojeek  403 access denied over Mullvad (fine through the proxy)
          #   google  403 on both the old /wml/search and upstream's new
          #           adtest endpoint (searxng#6835)
          #   qwant   API 403 AccessDenied
          # Retest by hand with `searxng-canary --per-engine` (../../../
          # modules/nixos/searxng-canary) before turning one back on;
          # `impersonate` (our patch, ./searxng-package.nix) was the
          # target that got through from Mullvad.
          ++ map
            (
              e:
              e
              // {
                disabled = true;
              }
            )
            (
              lib.filter (e: !lib.elem e.name rp.searxngEngines) [
                { name = "bing"; }
                {
                  name = "yahoo";
                  impersonate = "safari2601";
                }
                {
                  name = "brave";
                  impersonate = "chrome131_android";
                  network = "ipv4"; # 429 over the egress' IPv6
                }
                {
                  # stock-inactive: loaded only when proxied (below)
                  name = "mojeek";
                }
                { name = "google"; }
                { name = "qwant"; }
              ]
            )
          # Through the residential proxy: their own network with it and
          # the default exit country (the proxy username). The proxy, not
          # this host, resolves and dials the site; the extra hop needs
          # more than the 3 s default (DDG and the CSE time out at 3 s).
          ++ map (name: {
            inherit name;
            disabled = false;
            inactive = false;
            timeout = 8.0;
            network = {
              proxies."all://" = "http://${rp.defaultCountry}:***@${lib.removePrefix "http://" rp.url}";
              retries = 1;
            };
          }) rp.searxngEngines
          # Startpage: an Anubis challenge for every target (2026-11). Back
          # to stock-inactive on purpose (not even loaded) rather than
          # merely disabled; turn it on again by hand after a manual
          # retest, nothing retests it automatically.
          ++ [
            {
              name = "startpage";
              inactive = true;
            }
          ]
          # Wikipedia and Wikidata stay off (Dave, 2026-11): not loaded.
          # The Wikimedia two are slow from the egress (the 3 s default
          # times out): 6 s, for when they come back. OSM's map results
          # still ask the Wikidata SPARQL endpoint for images and links
          # (searx.wikidata.send_wikidata_query, a library call that needs
          # neither engine loaded) with the contact in its User-Agent.
          ++ [
            {
              name = "wikipedia";
              inactive = true;
              timeout = 6.0;
            }
            {
              name = "wikidata";
              inactive = true;
              timeout = 6.0;
            }
          ]
          # OpenStreetMap (Nominatim), stock: category `map` only, so it
          # answers only `categories=map` or `!osm`, never the general
          # searches hermes sends (its provider passes no categories).
          # Nominatim allows 1 request/s; SearXNG has no per-engine rate
          # limit, so one connection at a time, and map searches are rare.
          ++ [
            {
              name = "openstreetmap";
              disabled = false;
              categories = [ "map" ];
              max_connections = 1;
              # Nominatim plus, in the same step, the Wikidata SPARQL call
              # for images: the 3 s default times out from the egress.
              timeout = 6.0;
            }
          ];
        # Dave's default country is Singapore. With "all" Bing sends no
        # market and answers with unrelated results (searxng#4964); with
        # en-SG it and DuckDuckGo answer on topic. Engines without
        # regions use the language part.
        search.default_lang = "en-SG";
        # Upstream master (since 38929d14, 2026-11-12) loads Wikipedia,
        # Wikidata and OSM only with a contact, and puts it into the
        # User-Agent of its Wikimedia requests (Wikimedia's User-Agent
        # policy): for OSM that is the Wikidata SPARQL call for images;
        # Nominatim gets no contact. A role address on a domain that
        # names no one: the Porkbun mail forward search-bot@agentic-nix.com
        # (set up through the shared `porkbun` API key, not Nix-managed;
        # check or recreate it with Porkbun's email-forward API) to the
        # infra agent's receive-only mailbox (infra@<mail domain>; unknown
        # senders land in its quarantine).
        general.contact_url = "mailto:search-bot@agentic-nix.com";
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
