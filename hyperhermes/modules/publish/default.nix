# Web pages the agents serve, each port on a host of its own below the
# agent's name: <port>.<agent>.<domain> (exposure.urlOf: https on 443 in
# public mode, http://<port>.<agent>.hermes.localhost:8473 in local mode)
# -> nginx -> the owner's bridge -> the app on 127.0.0.1:<port>. The domain
# is the agent-controlled site (the dashboards module says why it is not the
# deployment's own); the port sits below the agent's name so that a Public
# Suffix List entry for the domain would make every agent a site of its own
# without further changes.
#
# Ports: each agent owns 10 loopback ports, servePortBase + (uid - 1000) *
# 10 .. +9, disjoint per uid and below the kernel's ephemeral range. The
# first five are PRIVATE: a login per host, and only the agent's own
# account (sso.accounts.<agent>) gets through. The last five are PUBLIC: no
# login. The agent picks the mode by picking the port; the URL cannot
# upgrade a private port to public, and a port under another agent's name
# is no server at all (exposure's catch-all answers 404).
#
# Private ports, per host:
#   - their own oauth2-proxy (`oauth2-proxy-serve`, its own cookie secret
#     `cookieSecretFile` and OIDC client `hermes-serve`, ../../lib/sso.nix),
#     apart from the front door's. Its login cookie is `__Host-hermes_serve`
#     (and `__Host-hermes_serve_csrf` during a sign-in): host-only by
#     browser rule, Secure, Path=/, so every port host has a login of its
#     own that no other host receives, sets or overwrites. Over local HTTP
#     no Secure cookie sticks: there it is `_hermes_serve`, host-only all
#     the same (no Domain attribute). With the issuer's session the second
#     and later sign-ins are silent (the client does not require
#     reauthentication).
#   - its endpoints sit below `/.hermes-serve-login/` on the port's own
#     host (a path apps do not use). No redirect-url: oauth2-proxy builds
#     the callback from X-Forwarded-Proto and X-Forwarded-Host, which nginx
#     sets to the scheme and host it matched (with exposure's port in local
#     mode), one of the exact private names below. The proxy listens on no
#     TCP port but on a unix socket systemd (root) holds for the whole
#     uptime (`http-address=fd:3`), root:nginx 0660 in /run: no agent can
#     talk to it past nginx, nor take its address while it is down or
#     restarting (a loopback port belongs to whoever binds it first). It
#     trusts X-Forwarded-* from that socket's peers, which means nginx. No
#     whitelist-domain: the post-login redirect may only be a path on the
#     same host. A request without a session is handed to /start
#     internally, with its URI as X-Auth-Request-Redirect.
#   - the issuer matches the callback. An issuer that takes host patterns
#     (pocket-id takes `*` in the host as a wildcard over any labels,
#     tested against v2.16.0's matchCallbackURL) gets one pattern per agent,
#     https://*.<agent>.<domain>/.hermes-serve-login/callback
#     (lib.sso.oidcClients without publishHosts): the ports derive from
#     uids that a clan inventory, which never evaluates a machine's config,
#     does not know. The pattern also covers the public ports and the agent
#     slot, which the agent controls; a code delivered there is useless to
#     it: the client is confidential (the secret lives only in
#     oauth2-proxy-serve's credentials) and every code is bound to a PKCE
#     verifier the proxy keeps in the visitor's CSRF cookie. sso.oidcClients
#     lists every private host's callback exactly (local dex matches
#     exactly).
#   - authorization: the issuer admits only the agents' groups to the
#     client (pocket-id per client; dex admits anyone, so in local mode the
#     proxy checks the `groups` claim itself: allowed-group, one per
#     agent). Then a map over "<host> <account>" (the ID token's
#     preferred_username) names the backend; each private host matches its
#     owner's account only, everything else lands on a 403 server on a
#     unix socket in /run/nginx (0750, nginx only). The map runs at
#     proxy_pass time, after auth_request_set, which an `if` would not.
#   - a Fetch Metadata gate (exposure): another origin (another agent's
#     page, a public port) cannot post, fetch or open a websocket here with
#     the visitor's login; links still work.
# The session cookie is sealed with one secret for every host: one copied
# from host A replays on host B, but it is the visitor's own login, and the
# map still checks the account against B's owner.
#
# Agents are untrusted, so nothing of the visitor's login reaches them:
#   - nginx forwards only an allowlist of cookies (./cookies.js, njs):
#     names that start with a letter or digit, plus jupyter's `_xsrf`.
#     Every login cookie starts with an underscore, so none passes, however
#     many there are. Apps that set their own cookies (a token-gated proxy,
#     jupyter) keep working,
#   - proxy_cookie_domain pins any Set-Cookie Domain to the serving host,
#     so an agent cannot plant cookies on its other hosts through headers
#     (document.cookie still can; residual, see the dashboards module),
#   - nginx never dials an app's port itself. Another agent could bind a
#     port while its owner's app is down (netfilter gates connect(2), never
#     bind(2)) and would then get the owner's visitors, their app cookies,
#     and on a public port a page under the owner's name. So nginx dials
#     /run/hermes-serve/<port>.sock, root:nginx 0660, which systemd holds
#     for the whole uptime, and each connection gets a bridge running as
#     the port's owner that refuses a backend another uid bound (core's
#     tcp-owner-bridge, as the dashboards' forwards). An app that is down,
#     or a squatter, gives 502, never someone else's page. A request flood
#     slows these sockets down but never stops them, and nginx limits
#     requests per client network and port host, and per port host alone,
#     with the dashboards module's zones (its header has the numbers and
#     their residual).
#   - the ports are owner-only on loopback (iptables, in the chain core's
#     firewall gates the dashboard ports in): the owner (and so its bridge)
#     and root may dial them, other agents may not. Nothing opens them in
#     the firewall.
#
# Origin: apps get `Host: 127.0.0.1:<port>` (dev servers such as vite and
# jupyter reject unknown hosts). A same-origin Origin (the port host's own
# origin) is rewritten to http://127.0.0.1:<port>, so an app's own
# Origin-vs-Host check (jupyter's) passes for its own pages; any other
# Origin reaches the app unchanged, so that check still refuses it.
#
# Transition (public mode, legacyFrontDoorPorts): the old names
# https://<port>.<front door>/ answer 301 to the new one, path and query
# kept, and serve nothing else; drop it once the old links are gone.
#
# Public mode, TLS: one wildcard cert per agent, *.<agent>.<domain>
# (hermes-publish-<agent>), by exposure's DNS-01; no port number lands in the
# CT logs. DNS (exposure.dnsRecords): *.<agent>.<domain> gets the wildcard's
# A and AAAA, no TXT (a wildcard TXT would answer _acme-challenge,
# exposure's header). The wildcard also covers the agent slot's name
# slot.<agent>.<domain>, so a browser may reuse a connection to one of
# these hosts (same v4 address) for the slot. On such a connection nginx
# answers the slot's name with 421 Misdirected Request, and the browser
# retries on a connection of its own, which reaches the slot by SNI.
# Local mode needs neither: *.localhost resolves to loopback by itself.
#
# The serve-ports skill (./skill, rendered with this host's port table and
# URL form) teaches the agent all of this.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.publish;
  agents = config.services.hyperhermes.agents;
  names = lib.attrNames agents;
  inherit (config.services.hyperhermes) exposure sso;
  inherit (exposure) domain;
  hlib = import ../../lib/core.nix { inherit lib; };
  ssoLib = import ../../lib/sso.nix { inherit lib; };
  inherit (hlib) chain ephemeralPortLow;
  tcpOwnerBridgeBin = config.services.hyperhermes.tcpOwnerBridge;
  public = exposure.mode == "public";
  inStore = path: lib.hasPrefix builtins.storeDir (toString path);

  # How the browser addresses a port host: scheme, and the port after the
  # host name (none on 443).
  scheme = if public then "https" else "http";
  hostPort = lib.optionalString (!public) ":${toString exposure.port}";
  # The Host the browser sent, as oauth2-proxy and the apps must rebuild
  # URLs from it. $host carries no port; exposure's is the only one nginx
  # serves these names on.
  forwardedHost = "$host${hostPort}";

  servePortBase = 30000;
  portsOf =
    name:
    let
      from = servePortBase + (agents.${name}.uid - 1000) * 10;
    in
    {
      inherit from;
      private = lib.genList (i: from + i) 5;
      public = lib.genList (i: from + 5 + i) 5;
      to = from + 9;
    };
  accountOf = name: sso.accounts.${name};
  hostOf = name: port: "${toString port}.${name}.${domain}";
  certOf = name: "hermes-publish-${name}";
  # What nginx dials for a port: a root-held socket whose connections a
  # bridge running as the owner forwards to the app (the header).
  backendDir = "/run/hermes-serve";
  backendOf = port: "unix:${backendDir}/${port}.sock";
  bridgeUnitOf = port: "hermes-serve-fwd-${toString port}";

  # The private ports' login (the header).
  clientId = ssoLib.publishClientId;
  loginPrefix = ssoLib.publishLoginPrefix;
  loginSocket = "/run/oauth2-proxy-serve.sock";
  login = "unix:${loginSocket}:";
  # `--flag=value` (toCommandLineShellGNU's form): oauth2-proxy's boolean
  # flags take no separate argument.
  loginArgs = lib.cli.toCommandLineShellGNU { } (
    {
      provider = "oidc";
      oidc-issuer-url = sso.issuer;
      client-id = clientId;
      client-secret-file = "%d/client-secret";
      cookie-secret-file = "%d/cookie-secret";
      cookie-name = if public then "__Host-hermes_serve" else "_hermes_serve";
      cookie-secure = lib.boolToString public;
      cookie-httponly = "true";
      cookie-samesite = "lax";
      proxy-prefix = loginPrefix;
      # The socket systemd holds (the header).
      http-address = "fd:3";
      upstream = "static://202";
      email-domain = "*";
      set-xauthrequest = "true";
      reverse-proxy = "true";
      # No TCP peer can reach it; peers of the unix socket (nginx) are
      # trusted regardless. Narrow anyway, or oauth2-proxy trusts every
      # address.
      trusted-proxy-ip = "127.0.0.1";
      # Accounts may have no email; identify them by username, as the
      # dashboards do.
      oidc-email-claim = "preferred_username";
      insecure-oidc-allow-unverified-email = "true";
      code-challenge-method = "S256";
      skip-provider-button = "true";
    }
    // lib.optionalAttrs (!public) {
      # dex admits every account to every client (the header).
      scope = "openid email profile groups";
      allowed-group = map ssoLib.groupOf names;
    }
  );
  # What oauth2-proxy-serve needs to see of the request it answers.
  loginHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto ${scheme};
    proxy_set_header X-Forwarded-Host ${forwardedHost};
  '';

  # Nothing of the agents listens here; nginx answers 403 from its own
  # server block, on a socket only nginx reaches.
  forbiddenSocket = "/run/nginx/hermes-serve-forbidden.sock";

  # The app's side of every published port, private or public.
  appLocation = backend: {
    proxyPass = "http://${backend}";
    proxyWebsockets = true;
    # Loopback Host: dev servers (vite, jupyter) reject unknown hosts; the
    # public one rides in X-Forwarded-Host.
    recommendedProxySettings = false;
    extraConfig = ''
      proxy_set_header Host 127.0.0.1:$hermes_serve_port;
      proxy_set_header Origin $hermes_serve_origin;
      proxy_set_header Cookie $hermes_serve_cookie;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host ${forwardedHost};
      proxy_cookie_domain ~.+ $host;
      proxy_read_timeout 1h;
      proxy_send_timeout 1h;
      client_max_body_size 256m;
    '';
  };
  vhostFor =
    name: ports:
    let
      hosts = map (hostOf name) ports;
    in
    {
      serverName = lib.head hosts;
      serverAliases = lib.tail hosts;
      # The request limits of the dashboards, zones and all (the
      # dashboards module says why and how much), per port host and client
      # network, and per port host alone (below the socket's
      # MaxConnections); on a private host they cover the sign-in too.
      extraConfig = ''
        limit_req zone=hermes_agent_requests burst=500 nodelay;
        limit_conn hermes_agent_conns 128;
        limit_conn hermes_agent_host_conns 384;
        limit_req_status 429;
        limit_conn_status 429;
      '';
    }
    // exposure.virtualHost (certOf name);

  portList = ps: lib.concatMapStringsSep ", " toString ps;
  skill = import ../../lib/agent-skill.nix pkgs {
    name = "serve-ports";
    src = pkgs.writeTextDir "SKILL.md" (
      builtins.replaceStrings
        [
          "@DOMAIN@"
          "@PORTS@"
          "@SCHEME@"
          "@LISTEN_PORT@"
          "@TLS@"
        ]
        [
          domain
          (lib.concatMapStringsSep "\n" (
            name:
            let
              p = portsOf name;
            in
            "| ${name} | ${portList p.private} | ${portList p.public} |"
          ) names)
          scheme
          hostPort
          (lib.optionalString public ", with TLS,")
        ]
        (builtins.readFile ./skill/SKILL.md)
    );
  };
in
{
  options.services.hyperhermes.publish = {
    enable = lib.mkEnableOption "10 published loopback ports per agent at <port>.<agent>.<domain>, 5 behind the owner's login, 5 public";

    cookieSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime path of oauth2-proxy-serve's cookie secret: 16, 24 or 32 bytes, raw or in URL-safe base64 (oauth2-proxy decodes no other base64).";
    };

    legacyFrontDoorPorts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Public mode, transition: https://<port>.<sso.frontDoor.host>/, the serve ports' old names, answers 301 to the port's name below the agent, nothing else.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions =
          lib.mapAttrsToList (name: a: {
            # The bridge would accept a self-connect inside the ephemeral
            # range (lib/core.nix, ephemeralPortLow).
            assertion = a.uid >= 1000 && (portsOf name).to < ephemeralPortLow config.boot.kernel.sysctl;
            message = "services.hyperhermes.agents.${name}: its serve ports (${toString servePortBase} + (uid - 1000) * 10 .. +9) must stay below the ephemeral port range (${toString (ephemeralPortLow config.boot.kernel.sysctl)}+); uid must be 1000 or above and low enough.";
          }) agents
          ++ [
            {
              assertion = sso.enable;
              message = "services.hyperhermes.publish needs services.hyperhermes.sso.enable.";
            }
            {
              # The request limit zones (vhostFor).
              assertion = config.services.hyperhermes.dashboards.enable or false;
              message = "services.hyperhermes.publish needs services.hyperhermes.dashboards.enable (its request limits).";
            }
            {
              assertion = !inStore cfg.cookieSecretFile;
              message = "services.hyperhermes.publish.cookieSecretFile must be a runtime path outside the Nix store.";
            }
            {
              assertion = cfg.legacyFrontDoorPorts -> public && sso.frontDoor.host != null;
              message = "services.hyperhermes.publish.legacyFrontDoorPorts needs exposure.mode = public and sso.frontDoor.host.";
            }
          ];

        services.hyperhermes.skillDirs = [ "${skill}/share/skills" ];

        # The client's callbacks, one per private host (../sso.nix).
        services.hyperhermes.sso.publishHosts = lib.genAttrs names (
          name: map (hostOf name) (portsOf name).private
        );

        # Loopback owner gate, after the module's own rules (they never name
        # these ports). nginx dials the bridges' sockets, never these ports.
        systemd.services.hermes-firewall.script = lib.mkAfter (
          lib.concatMapStrings (
            name:
            let
              ports = "${toString (portsOf name).from}:${toString (portsOf name).to}";
            in
            ''
              iptables -w -A ${chain} -p tcp --dport ${ports} -m owner --uid-owner ${name} -j RETURN
              iptables -w -A ${chain} -p tcp --dport ${ports} -m owner --uid-owner 0 -j RETURN
              iptables -w -A ${chain} -p tcp --dport ${ports} -j REJECT --reject-with tcp-reset
            ''
          ) names
        );

        # The sockets nginx dials, held by systemd for the whole uptime, and
        # per connection a bridge as the port's owner (the header). The
        # bridge dials base + 10 * its euid: this port, for the owner's uid.
        # No trigger limit, a raised poll limit and a deliberate
        # MaxConnections, as the dashboards' (core's forwards say why): a
        # public port takes a request flood from anyone, and nginx opens one
        # connection per request.
        systemd.sockets =
          lib.listToAttrs (
            lib.concatMap (
              name:
              map (
                port:
                lib.nameValuePair (bridgeUnitOf port) {
                  description = "Serve port ${toString port} of ${name}";
                  wantedBy = [ "sockets.target" ];
                  listenStreams = [ "${backendDir}/${toString port}.sock" ];
                  socketConfig = {
                    Accept = true;
                    TriggerLimitIntervalSec = 0;
                    PollLimitIntervalSec = "2s";
                    PollLimitBurst = 2000;
                    MaxConnections = 512;
                    SocketUser = "root";
                    SocketGroup = config.services.nginx.group;
                    SocketMode = "0660";
                  };
                }
              ) ((portsOf name).private ++ (portsOf name).public)
            ) names
          )
          // {
            # The private ports' login (the header).
            oauth2-proxy-serve = {
              description = "Socket of the hermes agents' private serve ports' oauth2-proxy";
              wantedBy = [ "sockets.target" ];
              listenStreams = [ loginSocket ];
              # No trigger limit, as the front door's (the sso module says
              # why).
              socketConfig = {
                TriggerLimitIntervalSec = 0;
                SocketUser = "root";
                SocketGroup = config.services.nginx.group;
                SocketMode = "0660";
              };
            };
          };

        systemd.services.oauth2-proxy-serve = {
          description = "oauth2-proxy of the hermes agents' private serve ports";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          requires = [ "oauth2-proxy-serve.socket" ];
          after = [
            "network-online.target"
            "oauth2-proxy-serve.socket"
          ];
          # OIDC discovery needs the issuer: retry every 5s, indefinitely,
          # until it answers (as the front door's instance).
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            ExecStart = "${lib.getExe pkgs.oauth2-proxy} ${loginArgs}";
            DynamicUser = true;
            LoadCredential = [
              "client-secret:${sso.clients.${clientId}.secretFile}"
              "cookie-secret:${cfg.cookieSecretFile}"
            ];
            Restart = "always";
            RestartSec = "5s";
            UMask = "0077";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            CapabilityBoundingSet = "";
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
              "~@resources"
            ];
          };
        };

        # Cross-origin requests on the private hosts (the header).
        services.hyperhermes.exposure.fetchMetadataGate.virtualHosts = map (
          name: "hermes-serve-${name}"
        ) names;

        services.nginx = {
          additionalModules = [ pkgs.nginxModules.njs ];
          appendHttpConfig = ''
            js_import hermes_serve_cookies from ${./cookies.js};
            js_set $hermes_serve_cookie hermes_serve_cookies.appCookies;

            map $host $hermes_serve_port {
              "~^(?<hermes_serve_port_label>[0-9]+)\." $hermes_serve_port_label;
            }

            # Same-origin Origin -> the loopback origin the app sees (the
            # header); anything else, an absent one included, unchanged.
            map "$http_origin $host" $hermes_serve_origin {
              default $http_origin;
              "~^${scheme}://([^ ]+)${lib.escapeRegex hostPort} \1$" "http://127.0.0.1:$hermes_serve_port";
            }

            map "$host $hermes_serve_account" $hermes_serve_backend {
              default unix:${forbiddenSocket};
            ${lib.concatMapStrings (
              name:
              lib.concatMapStrings (
                port: "  \"${hostOf name port} ${accountOf name}\" ${backendOf (toString port)};\n"
              ) (portsOf name).private
            ) names}}
          ''
          + lib.optionalString cfg.legacyFrontDoorPorts ''
            map $hermes_serve_legacy_port $hermes_serve_legacy {
              default "";
            ${lib.concatMapStrings (
              name:
              let
                p = portsOf name;
              in
              lib.concatMapStrings (port: "  ${toString port} ${hostOf name port};\n") (p.private ++ p.public)
            ) names}}
          '';

          virtualHosts =
            lib.listToAttrs (
              lib.concatMap (
                name:
                let
                  p = portsOf name;
                in
                [
                  (lib.nameValuePair "hermes-serve-${name}" (
                    vhostFor name p.private
                    // {
                      locations."${loginPrefix}/" = {
                        proxyPass = "http://${login}";
                        recommendedProxySettings = false;
                        extraConfig = loginHeaders;
                      };
                      locations."= /.hermes-serve-auth".extraConfig = ''
                        internal;
                        proxy_pass http://${login}${loginPrefix}/auth;
                        proxy_pass_request_body off;
                        proxy_set_header Content-Length "";
                        ${loginHeaders}
                      '';
                      # error_page's internal redirect: a GET, no arguments.
                      locations."= /.hermes-serve-start".extraConfig = ''
                        internal;
                        proxy_pass http://${login}${loginPrefix}/start;
                        proxy_pass_request_body off;
                        proxy_set_header Content-Length "";
                        proxy_set_header X-Auth-Request-Redirect $request_uri;
                        ${loginHeaders}
                      '';
                      locations."/" =
                        let
                          app = appLocation "$hermes_serve_backend";
                        in
                        app
                        // {
                          extraConfig = ''
                            auth_request /.hermes-serve-auth;
                            auth_request_set $hermes_serve_account $upstream_http_x_auth_request_preferred_username;
                            error_page 401 = /.hermes-serve-start;
                          ''
                          + app.extraConfig;
                        };
                    }
                  ))
                  (lib.nameValuePair "hermes-serve-public-${name}" (
                    vhostFor name p.public
                    // {
                      locations."/" = appLocation (backendOf "$hermes_serve_port");
                    }
                  ))
                ]
                # The slot's name on a reused connection (the header).
                ++ lib.optional public (
                  lib.nameValuePair "hermes-serve-slot-${name}" {
                    serverName = "slot.${name}.${domain}";
                    onlySSL = true;
                    useACMEHost = certOf name;
                    locations."/".return = "421";
                  }
                )
              ) names
            )
            // {
              hermes-serve-forbidden = {
                serverName = "_";
                listen = [ { addr = "unix:${forbiddenSocket}"; } ];
                locations."/".return = "403 'Not published, or not published for this account.\\n'";
                extraConfig = "default_type text/plain;";
              };
            }
            // lib.optionalAttrs cfg.legacyFrontDoorPorts {
              # Transition only: 301 to the new name, never a backend, on 80
              # and 443 alike. Let's Encrypt follows redirects in HTTP-01, so
              # a challenge path that redirected into an agent's page would
              # hand the agent a certificate for a name of the deployment's
              # site: 404 for those (and exposure.acme.caa allows DNS-01
              # only). The certificate is the sso module's front door one,
              # which covers every name below the front door.
              hermes-serve-legacy = {
                serverName = "~^(?<hermes_serve_legacy_port>[0-9]+)\\.${lib.escapeRegex sso.frontDoor.host}$";
                addSSL = true;
                useACMEHost = "hermes-subdomains";
                locations."^~ /.well-known/acme-challenge/".return = "404";
                locations."/".extraConfig = ''
                  if ($hermes_serve_legacy = "") {
                    return 404;
                  }
                  return 301 https://$hermes_serve_legacy$request_uri;
                '';
              };
            };
        };
      }

      # --- public mode: DNS and TLS (the header) ------------------------
      (lib.mkIf public {
        services.hyperhermes.exposure.records = lib.mkIf (exposure.hostRecords != { }) (
          lib.genAttrs (map (name: "*.${name}.${domain}") names) (
            _: removeAttrs exposure.hostRecords [ "TXT" ]
          )
        );
        security.acme.certs = lib.listToAttrs (
          map (name: lib.nameValuePair (certOf name) (exposure.acmeCert "*.${name}.${domain}")) names
        );
      })

      # The bridges behind the sockets above, as the port's owner. stderr
      # goes to the journal, or StandardInput=socket would send a refusal
      # to nginx. Refused connections leave no failed unit behind
      # (CollectMode, as core's forwards).
      {
        systemd.services = lib.listToAttrs (
          lib.concatMap (
            name:
            map (
              port:
              lib.nameValuePair "${bridgeUnitOf port}@" {
                description = "Serve port ${toString port} of ${name}, bridged";
                serviceConfig = {
                  User = name;
                  ExecStart = "${tcpOwnerBridgeBin}/bin/hermes-tcp-owner-bridge ${
                    toString (port - 10 * agents.${name}.uid)
                  } 10";
                  StandardInput = "socket";
                  StandardError = "journal";
                };
                unitConfig.CollectMode = "inactive-or-failed";
              }
            ) ((portsOf name).private ++ (portsOf name).public)
          ) names
        );
      }
    ]
  );
}
