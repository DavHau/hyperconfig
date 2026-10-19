# Web pages the native hermes agents serve, each port on a host of its own
# below the agent's name: https://<port>.<agent>.<agentDomain>/ (on som
# <port>.<agent>.davhau.fyi) -> nginx -> the owner's bridge -> the app on
# 127.0.0.1:<port>. agentDomain is
# the agent-controlled site (./hermes-dashboard-public.nix says why it is
# not davhau.com); the port sits below the agent's name so that a Public
# Suffix List entry for davhau.fyi would make every agent a site of its own
# without further changes.
#
# Ports: each agent owns 10 loopback ports, servePortBase + (uid - 1000) * 10
# .. +9, disjoint per uid and below the kernel's ephemeral range (32768+).
# The first five are PRIVATE: a pocket-id login per host, and only the
# agent's own dashboard account (hyper.hermesDashboard.users.<name>.account)
# gets through. The last five are PUBLIC: no login. The agent picks the
# mode by picking the port; the URL cannot upgrade a private port to
# public, and a port under another agent's name is no server at all (the
# catch-all of ./hermes-dashboard-public.nix answers 404).
#
# Private ports, per host:
#   - their own oauth2-proxy (`oauth2-proxy-serve`, its own cookie secret
#     and pocket-id client `hermes-serve`), apart from the davhau.com front
#     door's. Its login cookie is `__Host-hermes_serve` (and
#     `__Host-hermes_serve_csrf` during a sign-in): host-only by browser
#     rule, Secure, Path=/, so every port host has a login of its own that
#     no other host receives, sets or overwrites. With pocket-id's session
#     the second and later sign-ins are silent (the client does not require
#     reauthentication).
#   - its endpoints sit below `/.hermes-serve-login/` on the port's own
#     host (a path apps do not use). No redirect-url: oauth2-proxy builds
#     the callback from X-Forwarded-Host, which nginx sets to the host it
#     matched, one of the exact private names below. The proxy listens on
#     no TCP port but on a unix socket systemd (root) holds for the whole
#     uptime (`http-address=fd:3`), root:nginx 0660 in /run: no agent can
#     talk to it past nginx, nor take its address while it is down or
#     restarting (a loopback port belongs to whoever binds it first). It
#     trusts X-Forwarded-* from that socket's peers, which means nginx. No
#     whitelist-domain: the post-login redirect may only be a path on the
#     same host. A request without a session is handed to /start
#     internally, with its URI as X-Auth-Request-Redirect.
#   - pocket-id matches the callback against
#     https://*.<agent>.<agentDomain>/.hermes-serve-login/callback, one
#     pattern per agent: pocket-id takes `*` in the host as a wildcard over
#     any labels (tested against v2.16.0's matchCallbackURL), and the ports
#     derive from uids that the inventory, which never evaluates a
#     machine's config, does not know. The pattern also covers the public
#     ports and the agent slot, which the agent controls; a code delivered
#     there is useless to it: the client is confidential (the secret lives
#     only in oauth2-proxy-serve's credentials) and every code is bound to a
#     PKCE verifier the proxy keeps in the visitor's CSRF cookie.
#   - authorization: a map over "<host> <account>" names the backend;
#     each private host matches its owner's account only, everything else
#     lands on a 403 server on a unix socket in /run/nginx (0750, nginx
#     only). The map runs at proxy_pass time, after auth_request_set,
#     which an `if` would not.
#   - a Fetch Metadata gate (./fetch-metadata-gate.nix): another origin
#     (another agent's page, a public port) cannot post, fetch or open a
#     websocket here with the visitor's login; links still work.
# The session cookie is sealed with one secret for every host: one copied
# from host A replays on host B, but it is the visitor's own login, and the
# map still checks the account against B's owner.
#
# Agents are untrusted, so nothing of the visitor's login reaches them:
#   - nginx forwards only an allowlist of cookies
#     (./hermes-agents-serve-cookies.js, njs): names that start with a
#     letter or digit, plus jupyter's `_xsrf`. Every login cookie starts with
#     an underscore (`__Host-hermes_serve*`), so none passes, however many
#     there are. Apps that set their own cookies (a token-gated proxy,
#     jupyter) keep working,
#   - proxy_cookie_domain pins any Set-Cookie Domain to the serving host,
#     so an agent cannot plant cookies on its other hosts through headers
#     (document.cookie still can; residual, see the dashboard module),
#   - nginx never dials an app's port itself. Another agent could bind a
#     port while its owner's app is down (netfilter gates connect(2), never
#     bind(2)) and would then get the owner's visitors, their app cookies,
#     and on a public port a page under the owner's name. So nginx dials
#     /run/hermes-serve/<port>.sock, root:nginx 0660, which systemd holds
#     for the whole uptime, and each connection gets a bridge running as
#     the port's owner that refuses a backend another uid bound
#     (./hermes-native/tcp-owner-bridge.rs, as the dashboards'
#     ./hermes-native/forwards.nix). An app that is down, or a squatter,
#     gives 502, never someone else's page.
#   - the ports are owner-only on loopback (iptables, the same chain
#     ./hermes-native/firewall.nix gates the dashboard ports in): the owner
#     (and so its bridge) and root may dial them, other agents may not.
#     Nothing opens them in the firewall.
#
# Origin: apps get `Host: 127.0.0.1:<port>` (dev servers such as vite and
# jupyter reject unknown hosts). A same-origin Origin (https://<the host>)
# is rewritten to http://127.0.0.1:<port>, so an app's own Origin-vs-Host
# check (jupyter's) passes for its own pages; any other Origin reaches the
# app unchanged, so that check still refuses it.
#
# Transition (hyper.hermesDashboard.legacy.servePorts): the old names
# https://<port>.<host>/ answer 301 to the new one, path and query kept, and
# serve nothing else; drop it once the old links are gone.
#
# TLS: one wildcard cert per agent, *.<agent>.<agentDomain>, via porkbun
# DNS-01; no port number lands in the CT logs. DNS: *.<agent>.<agentDomain>
# A (sgp's v4, forwarded by ./ipv4-forward.nix) and AAAA (this host's
# networking.publicIPv6), TXT "v=spf1 -all", kept by ./porkbun-records; the
# agent slot's name has records of its own (./agent-slots.nix). The
# wildcard also covers the slot's name slot.<agent>.<agentDomain>, so a
# browser may reuse a connection to one of these hosts (same v4 address)
# for the slot. On such a connection nginx answers the slot's name with
# 421 Misdirected Request, and the browser retries on a connection of its
# own, which reaches the slot by SNI.
#
# The serve-ports skill (./hermes-agents-serve-skill, rendered with this
# host's port table) teaches the agent all of this.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  agents = config.hyper.hermesAgents;
  names = lib.attrNames agents;
  dashboard = config.hyper.hermesDashboard;
  domain = dashboard.agentDomain;
  inherit (import ./hermes-native/lib.nix { inherit lib; }) chain;
  tcpOwnerBridgeBin = import ./hermes-native/tcp-owner-bridge.nix { inherit pkgs; };
  vars = config.clan.core.vars.generators;

  servePortBase = 30000;
  portsOf =
    name:
    let
      from = servePortBase + (config.users.users.${name}.uid - 1000) * 10;
    in
    {
      inherit from;
      private = lib.genList (i: from + i) 5;
      public = lib.genList (i: from + 5 + i) 5;
      to = from + 9;
    };
  accountOf = name: dashboard.users.${name}.account;
  hostOf = name: port: "${toString port}.${name}.${domain}";
  certOf = name: "hermes-fyi-${name}";
  # What nginx dials for a port: a root-held socket whose connections a
  # bridge running as the owner forwards to the app (the header).
  backendDir = "/run/hermes-serve";
  backendOf = port: "unix:${backendDir}/${port}.sock";
  bridgeUnitOf = port: "hermes-serve-fwd-${toString port}";

  # The private ports' login (the header).
  clientId = "hermes-serve";
  client = config.hyper.oidc.clients.${clientId} or null;
  loginPrefix = "/.hermes-serve-login";
  loginSocket = "/run/oauth2-proxy-serve.sock";
  login = "unix:${loginSocket}:";
  callbackFor = name: "https://*.${name}.${domain}${loginPrefix}/callback";
  # `--flag=value` (toCommandLineShellGNU's form): oauth2-proxy's boolean
  # flags take no separate argument.
  loginArgs = lib.cli.toCommandLineShellGNU { } {
    provider = "oidc";
    oidc-issuer-url = config.hyper.oidc.issuer;
    client-id = clientId;
    client-secret-file = "%d/client-secret";
    cookie-secret-file = "%d/cookie-secret";
    cookie-name = "__Host-hermes_serve";
    cookie-secure = "true";
    cookie-httponly = "true";
    cookie-samesite = "lax";
    proxy-prefix = loginPrefix;
    # The socket systemd holds (the header).
    http-address = "fd:3";
    upstream = "static://202";
    email-domain = "*";
    set-xauthrequest = "true";
    reverse-proxy = "true";
    # No TCP peer can reach it; peers of the unix socket (nginx) are trusted
    # regardless. Narrow anyway, or oauth2-proxy trusts every address.
    trusted-proxy-ip = "127.0.0.1";
    # Accounts may have no email; identify them by username, as the
    # dashboards do.
    oidc-email-claim = "preferred_username";
    insecure-oidc-allow-unverified-email = "true";
    code-challenge-method = "S256";
    skip-provider-button = "true";
  };
  # What oauth2-proxy-serve needs to see of the request it answers.
  loginHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host $host;
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
      proxy_set_header X-Forwarded-Host $host;
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
      forceSSL = true;
      useACMEHost = certOf name;
    };

  portList = ps: lib.concatMapStringsSep ", " toString ps;
  skill = inputs.spaces.lib.mkAgentSkill pkgs {
    name = "serve-ports";
    src = pkgs.writeTextDir "SKILL.md" (
      builtins.replaceStrings
        [ "@DOMAIN@" "@PORTS@" ]
        [
          domain
          (lib.concatMapStringsSep "\n" (
            name:
            let
              p = portsOf name;
            in
            "| ${name} | ${portList p.private} | ${portList p.public} |"
          ) names)
        ]
        (builtins.readFile ./hermes-agents-serve-skill/SKILL.md)
    );
  };
in
{
  config = lib.mkIf (agents != { }) (
    lib.mkMerge [
      {
    assertions =
      lib.mapAttrsToList (name: _: {
        assertion =
          let
            uid = config.users.users.${name}.uid;
          in
          uid == null || (uid >= 1000 && (portsOf name).to < 32768);
        message = "hyper.hermesAgents.${name}: uid must be in 1000..1276 so its serve ports (${toString servePortBase} + (uid - 1000) * 10) stay below the ephemeral range.";
      }) agents
      ++ [
        {
          assertion =
            client != null
            && !client.public
            && client.secretFile != null
            && client.pkce
            && client.callbackURLs == map callbackFor names
            && client.allowedGroups == map (name: "hermes-${name}") names;
          message = "hermes-agents-serve: the inventory must declare the confidential oidc client ${clientId} for this machine, with pkce, callbacks ${toString (map callbackFor names)} and groups ${toString (map (name: "hermes-${name}") names)} (derived from machines/<machine>/hermes-dashboards.nix).";
        }
      ];

    services.hermes-native.settings.skills.external_dirs = [ "${skill}/share/skills" ];

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
    # per connection a bridge as the port's owner (the header). The bridge
    # dials base + 10 * its euid: this port, for the owner's uid.
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
          socketConfig = {
            SocketUser = "root";
            SocketGroup = config.services.nginx.group;
            SocketMode = "0660";
          };
        };
      };

    # --- the private ports' login (the header) -----------------------------
    clan.core.vars.generators = {
      hermes-serve-oauth2-proxy = {
        files.cookie_secret.restartUnits = [ "oauth2-proxy-serve.service" ];
        runtimeInputs = [
          pkgs.coreutils
          pkgs.openssl
        ];
        # 32 hex characters are 32 raw bytes (./agent-mail/owner-page.nix
        # says why not base64).
        script = ''
          openssl rand -hex 16 | tr -d '\n' > "$out"/cookie_secret
        '';
      };
      "oidc-client-${clientId}".files.secret.restartUnits = [ "oauth2-proxy-serve.service" ];
      # Shared var, same definition as ./dyndns-porkbun.nix; only DNS-01
      # reads it here.
      porkbun = {
        share = true;
        prompts.apikey.type = "hidden";
        prompts.apikey.persist = true;
        prompts.secretkey.type = "hidden";
        prompts.secretkey.persist = true;
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
        LoadCredential = lib.optional (client != null && client.secretFile != null) "client-secret:${client.secretFile}" ++ [
          "cookie-secret:${vars.hermes-serve-oauth2-proxy.files.cookie_secret.path}"
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
    hyper.fetchMetadataGate.virtualHosts = map (name: "hermes-serve-${name}") names;

    # --- DNS and TLS (the header) -----------------------------------------
    hyper.porkbunRecords.records = lib.mkIf (dashboard.publicIPv4 != null) (
      lib.genAttrs (map (name: "*.${name}.${domain}") names) (_: {
        A = dashboard.publicIPv4;
        TXT = "v=spf1 -all";
        AAAA.ipv6OnLink = {
          inherit (config.networking.publicIPv6) interface;
          suffix = config.networking.publicIPv6.token;
        };
      })
    );
    security.acme.certs = lib.listToAttrs (
      map (
        name:
        lib.nameValuePair (certOf name) {
          domain = "*.${name}.${domain}";
          dnsProvider = "porkbun";
          # Not an enableACME cert, so the nginx module leaves the group alone.
          group = "nginx";
          credentialFiles = {
            PORKBUN_API_KEY_FILE = vars.porkbun.files.apikey.path;
            PORKBUN_SECRET_API_KEY_FILE = vars.porkbun.files.secretkey.path;
          };
          # As the dashboards' cert (./hermes-dashboard-public.nix).
          dnsResolver = "1.1.1.1:53";
        }
      ) names
    );

    services.nginx = {
      additionalModules = [ pkgs.nginxModules.njs ];
      appendHttpConfig = ''
        js_import hermes_serve_cookies from ${./hermes-agents-serve-cookies.js};
        js_set $hermes_serve_cookie hermes_serve_cookies.appCookies;

        map $host $hermes_serve_port {
          "~^(?<hermes_serve_port_label>[0-9]+)\." $hermes_serve_port_label;
        }

        # Same-origin Origin -> the loopback origin the app sees (the
        # header); anything else, an absent one included, unchanged.
        map "$http_origin $host" $hermes_serve_origin {
          default $http_origin;
          "~^https://([^ ]+) \1$" "http://127.0.0.1:$hermes_serve_port";
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
      + lib.optionalString dashboard.legacy.servePorts ''
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
              # The slot's name on a reused connection (the header).
              (lib.nameValuePair "hermes-serve-slot-${name}" {
                serverName = "slot.${name}.${domain}";
                onlySSL = true;
                useACMEHost = certOf name;
                locations."/".return = "421";
              })
            ]
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
        // lib.optionalAttrs dashboard.legacy.servePorts {
          # Transition only: 301 to the new name, never a backend, on 80 and
          # 443 alike. Let's Encrypt follows redirects in HTTP-01, so a
          # challenge path that redirected into an agent's page would hand
          # the agent a certificate for a davhau.com name: 404 for those (and
          # CAA allows DNS-01 only, ./hermes-dashboard-public.nix).
          hermes-serve-legacy = {
            serverName = "~^(?<hermes_serve_legacy_port>[0-9]+)\\.${lib.escapeRegex dashboard.host}$";
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
      # The bridges behind the sockets above, as the port's owner. stderr
      # goes to the journal, or StandardInput=socket would send a refusal
      # to nginx.
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
                    toString (port - 10 * config.users.users.${name}.uid)
                  } 10";
                  StandardInput = "socket";
                  StandardError = "journal";
                };
              }
            ) ((portsOf name).private ++ (portsOf name).public)
          ) names
        );
      }
    ]
  );
}
