# How the agents' web surfaces are reached: one nginx that routes by Host
# under a base domain. Every feature that publishes something (dashboards,
# the identity provider, serve ports) adds a virtual host built with
# `virtualHost` and builds its URLs with `urlOf`, so the same routing works
# in every mode.
#
# Local mode serves plain HTTP on a loopback port under a *.localhost
# domain: browsers resolve every *.localhost name to loopback by themselves
# and treat it as a secure context, and glibc does the same through
# nss-myhostname (on by default in NixOS), so the same URLs work for a
# browser on the host and for processes on this machine. Run in a NixOS
# container with a private network, the container listens on its own
# address too and the host forwards its loopback port there
# (checks/local-sso shows the setup).
#
# Public mode serves HTTPS on 443 (80 redirects) under a registrable domain
# of the deployment's. TLS: one wildcard certificate per name family, by
# ACME DNS-01 (lego, `acme.dnsProvider` with its credentials as runtime
# files), so no agent name lands in the CT logs before it is published.
# DNS: this module keeps no records itself; `dnsRecords` lists what the
# deployment's DNS must hold (the wildcard *.<domain> to `publicIPv4` and
# `publicIPv6`, plus what features add), for whatever keeps its zone.
# No TXT on the wildcards: a wildcard TXT also answers
# _acme-challenge.<name> until lego creates that record, resolvers cache
# that answer, and the DNS-01 propagation check then times out. Names below
# the domain send no mail: the _dmarc record's sp=reject covers them, the
# apex gets "v=spf1 -all" (features give their own names the same).
#
# Fetch Metadata gate (`fetchMetadataGate.virtualHosts`): refuse (403) what
# a browser marks as sent from another origin, unless it is a plain
# top-level navigation (the Sec-Fetch-* request headers).
#   Why: every agent's pages share one site, <domain>, until that domain is
#   on the Public Suffix List. To the browser, agent A's page is then
#   same-site with agent B's dashboard and private serve ports, so B's
#   SameSite=Lax login cookies ride along on every form post, fetch or
#   websocket A's page starts there. Host-only cookies and per-agent OIDC
#   clients stop A from reading or setting B's logins, not from using them
#   through the visitor's browser (CSRF). This gate does, on the vhosts it
#   is applied to.
#   Allowed: no Sec-Fetch-Site at all (not a browser: curl, the Hermes
#   Mobile app's OkHttp client; or one too old to send it); Sec-Fetch-Site
#   same-origin or none (typed URL, bookmark, a link opened from another
#   app, a Custom Tab); same-site and cross-site only as a top-level
#   navigation without side effects: Sec-Fetch-Mode navigate, method GET or
#   HEAD, Sec-Fetch-Dest document (or absent). Links and redirects keep
#   working, the OIDC callbacks among them (the issuer redirects there
#   cross-site, by GET).
#   Refused: everything else from another origin, i.e. form posts, fetch
#   and XHR, websockets, iframes, images, scripts.
#   Residual: a cross-origin GET navigation passes, so an app with side
#   effects on GET stays exposed to links; browsers without Fetch Metadata
#   (Safari before 16.4) are not protected.
#   What it breaks (no security impact): a cross-site top-level POST is
#   refused, so an OIDC provider answering with response_mode=form_post
#   would fail at the callback (hermes and oauth2-proxy use the query mode),
#   and so would an app's own cross-site form posts to these hosts. A
#   client still posting to an old name (a stale Hermes Mobile server
#   address) loses the body anyway: a 301 to the new name turns the POST
#   into a GET.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hyperhermes.exposure;
  public = cfg.mode == "public";
  urlLib = import ../lib/url.nix { inherit lib; };
  inStore = path: lib.hasPrefix builtins.storeDir (toString path);

  wildcardRecord =
    lib.optionalAttrs (cfg.publicIPv4 != null) { A = cfg.publicIPv4; }
    // lib.optionalAttrs (cfg.publicIPv6 != null) { AAAA = cfg.publicIPv6; };
in
{
  options.services.hyperhermes.exposure = {
    enable = lib.mkEnableOption "the nginx front for the agents' web surfaces";

    mode = lib.mkOption {
      type = lib.types.enum [
        "local"
        "public"
      ];
      default = "local";
      description = ''
        `local`: plain HTTP on `port`, reachable from this machine (or its
        container host) only. `public`: HTTPS on 443 under `domain`, with
        ACME certificates and the DNS records in `dnsRecords`.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default =
        if public then
          throw "services.hyperhermes.exposure.domain must be set in public mode"
        else
          "hermes.localhost";
      defaultText = lib.literalMD "`hermes.localhost` in local mode; required in public mode";
      description = ''
        Base domain; every published name sits below it. In public mode a
        registrable domain of its own: everything below it is
        agent-controlled, so it must be a different site than anything the
        deployment serves itself (its identity provider, its front door).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8473;
      description = "Local mode: port nginx serves on, part of every URL.";
    };

    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "127.0.0.1"
        "[::1]"
      ];
      description = ''
        Local mode: addresses nginx listens on. nss-myhostname answers
        *.localhost with both ::1 and 127.0.0.1, so loopback means both
        families. A container adds its private address for the host's
        forward.
      '';
    };

    publicIPv4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.0.2.1";
      description = "Public mode: the A records' address of every published name. Null: no A records.";
    };

    publicIPv6 = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.attrsOf lib.types.anything));
      default = null;
      example = "2001:db8::1";
      description = ''
        Public mode: the AAAA records' content of every published name, an
        address or whatever the deployment's DNS updater computes one from at
        sync time (passed through into `dnsRecords` unchanged). Null: no
        AAAA records.
      '';
    };

    acme = {
      dnsProvider = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "porkbun";
        description = "Public mode: lego DNS provider of the DNS-01 challenges.";
      };
      credentialFiles = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          PORKBUN_API_KEY_FILE = "/run/secrets/porkbun-apikey";
        };
        description = ''
          Public mode: the provider's credentials, lego `<VAR>_FILE`
          environment name -> runtime path (systemd credentials of the
          renewal units, never in the store).
        '';
      };
      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public mode: the ACME account's contact address.";
      };
      dnsResolver = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "1.1.1.1:53";
        description = "Public mode: resolver lego asks (zone lookup, propagation check); null: the system's.";
      };
      caa = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = ''0 issue "letsencrypt.org; validationmethods=dns-01"'';
        description = ''
          Public mode: CAA record on the names that are no agent's (the front
          door, legacy domains), so a CA issues for them only the way this
          module asks (DNS-01, whose key only root holds), never through an
          HTTP-01 challenge an agent-controlled redirect could answer.
        '';
      };
    };

    fetchMetadataGate.virtualHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "nginx virtualHosts (attribute names) that answer 403 to browser requests from another origin, top-level GET navigations excepted (the header).";
    };

    records = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      internal = true;
      description = "name -> type -> content; features add their names' records, dnsRecords lists them.";
    };

    dnsRecords = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      description = ''
        Public mode: the records the deployment's DNS must hold, as
        `{ name; type; value; }` (value: a string, or `publicIPv6` as given).
      '';
    };

    hostRecords = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      description = "The A/AAAA (and no-mail TXT) records a published name of a feature gets.";
    };

    certName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "hermes-fyi";
      description = "Public mode: the security.acme cert of *.<domain>.";
    };

    acmeCert = lib.mkOption {
      type = lib.types.functionTo (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      description = "Public mode: domain -> a security.acme.certs entry, by DNS-01 with `acme`, readable by nginx.";
    };

    nginxListen = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      description = "`listen` of every virtual host a feature publishes (empty in public mode: nginx' defaults).";
    };

    virtualHost = lib.mkOption {
      type = lib.types.functionTo (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      description = "certificate name -> the listen and TLS part of a published virtual host.";
    };

    urlOf = lib.mkOption {
      type = lib.types.functionTo lib.types.str;
      readOnly = true;
      description = "Origin (scheme, host, port) of a published host name.";
    };
  };

  config = lib.mkMerge [
    {
      services.hyperhermes.exposure = {
        nginxListen = lib.optionals (!public) (
          map (addr: {
            inherit addr;
            inherit (cfg) port;
          }) cfg.listenAddresses
        );
        virtualHost =
          cert:
          if public then
            {
              forceSSL = true;
              useACMEHost = cert;
            }
          else
            { listen = cfg.nginxListen; };
        urlOf =
          if public then
            urlLib.originOf { }
          else
            urlLib.originOf {
              scheme = "http";
              inherit (cfg) port;
            };
        acmeCert =
          domain:
          {
            inherit domain;
            inherit (cfg.acme) dnsProvider;
            # Not an enableACME cert, so the nginx module leaves the group alone.
            group = "nginx";
            credentialFiles = cfg.acme.credentialFiles;
          }
          // lib.optionalAttrs (cfg.acme.dnsResolver != null) { inherit (cfg.acme) dnsResolver; };
        hostRecords = lib.optionalAttrs (wildcardRecord != { }) (
          wildcardRecord // { TXT = "v=spf1 -all"; }
        );
        dnsRecords = lib.concatLists (
          lib.mapAttrsToList (
            name: byType: lib.mapAttrsToList (type: value: { inherit name type value; }) byType
          ) cfg.records
        );
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = public -> cfg.acme.dnsProvider != null;
          message = "services.hyperhermes.exposure: public mode needs acme.dnsProvider.";
        }
        {
          assertion = !lib.any inStore (lib.attrValues cfg.acme.credentialFiles);
          message = "services.hyperhermes.exposure.acme.credentialFiles must be runtime paths outside the Nix store.";
        }
      ];

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        # Names nothing publishes get no answer rather than some feature's
        # page, on the domain's wildcard and as the default server for any
        # other Host.
        virtualHosts.hermes-default = cfg.virtualHost cfg.certName // {
          serverName = "*.${cfg.domain}";
          default = true;
          locations."/".return = "404";
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.fetchMetadataGate.virtualHosts != [ ]) {
      # site:mode:method:dest. 1: no site, same-origin or none. 2: a
      # top-level navigation by GET or HEAD.
      services.nginx.appendHttpConfig = ''
        map "$http_sec_fetch_site:$http_sec_fetch_mode:$request_method:$http_sec_fetch_dest" $fetch_metadata_refused {
          default 1;
          "~^(same-origin|none)?:" 0;
          "~^[^:]*:navigate:(GET|HEAD):(document)?$" 0;
        }
      '';
      services.nginx.virtualHosts = lib.genAttrs cfg.fetchMetadataGate.virtualHosts (_: {
        extraConfig = ''
          if ($fetch_metadata_refused) {
            return 403 "Refused: a request from another site.\n";
          }
        '';
      });
    })

    (lib.mkIf (cfg.enable && public) {
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
      security.acme = {
        acceptTerms = true;
        defaults.email = lib.mkIf (cfg.acme.email != null) cfg.acme.email;
        certs.${cfg.certName} = cfg.acmeCert "*.${cfg.domain}";
      };
      services.hyperhermes.exposure.records = lib.mkIf (wildcardRecord != { }) {
        "*.${cfg.domain}" = wildcardRecord;
        ${cfg.domain}.TXT = "v=spf1 -all";
        "_dmarc.${cfg.domain}".TXT = "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s";
      };
    })
  ];
}
