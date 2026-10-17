# Public web dashboards for native hermes agents, one hostname per agent:
# https://<agent>.<agentDomain>/ -> nginx -> the root-held dashboard port of
# that agent (./hermes-native/forwards.nix), which bridges to the agent's
# loopback backend after checking the backend's owner.
#
# The login is hermes' own: the dashboard runs gated, with its bundled
# `self_hosted` OIDC provider against the clan's pocket-id
# (modules/clan/oidc). Each agent has its own CONFIDENTIAL pocket-id client
# `hermes-<agent>` (PKCE plus a client secret), callback
# https://<agent>.<agentDomain>/auth/callback, open to the group
# `hermes-<agent>` only. The agent is the relying party, so it may hold its
# own client's secret; what the secret stops is everyone else using that
# client id. pocket-id lets any client run the device-code grant, and for a
# public client the id alone would do: anyone could start one for
# hermes-<agent>, have a member approve the genuine-looking code page and
# walk away with that agent's ID and refresh tokens. The secret is the
# oidc service's shared clan var `oidc-client-hermes-<agent>` (generated,
# no prompt; on the pocket-id server and here). It rides a systemd
# credential into the agent's unit and lands in the owner's 0600 .env as
# HERMES_DASHBOARD_OIDC_CLIENT_SECRET (services.hermes-native secretEnv),
# never in the store or the managed dir; hermes sends it with HTTP Basic,
# which pocket-id's discovery offers. The clients also require
# re-authentication: every authorization asks for the passkey, even with a
# live pocket-id session, so a sign-in never completes silently. Hermes'
# native-app flow accepts any http://127.0.0.1:<port> redirect, and a
# local program listening there would otherwise collect a login it started
# itself in the browser.
#
# The inventory derives the clients and the group memberships from
# machines/som/hermes-dashboards.nix, which machines/som reads for the
# accounts too; the assertions below catch a client that does not match.
# Browsers and the Hermes Mobile app (RFC 8252 native PKCE, brokered by
# the dashboard's /auth/native/*) sign in the same way.
#
# Trust: the agent behind a dashboard is untrusted and IS the relying party.
# That is fine here because everything that would make its login worth
# stealing is per agent: the client (ID tokens are aud-bound to
# hermes-<agent>; hermes verifies signature, iss and aud), the hostname
# (its `__Host-` session cookies reach no other site), pocket-id's group
# restriction (only that agent's accounts get a token at all), and the
# passkeys (bound to the issuer's origin, never to the dashboard's). The
# agent can switch its own gate off; it could already publish itself
# through an outbound tunnel, so that opens nothing new. Kept out of reach
# is doing so with a plain edit of its env files (a prompt-injected write
# to .env or .op.env, no code run): before every dashboard start the keys
# that turn the gate off or add another way in are dropped from both
# (dashboardDropEnv below; from hermes 345cd2b: web_server.py
# exempts a loopback backend with HERMES_DESKTOP=1 plus a
# HERMES_DASHBOARD_SESSION_TOKEN, the basic, nous and drain providers of
# plugins/dashboard_auth register from their env keys, and
# HERMES_MANAGED_DIR would move the managed scope), and the config keys
# that register the basic or nous provider are pinned empty. Not pinned in
# the managed .env: hermes-desktop's `hermes serve` for dave-hermes
# (./hermes-desktop-dave-hermes.nix) gets HERMES_DESKTOP=1 in its process
# env, and the managed .env would override it. What remains is the
# residual above: an agent process can rewrite the files between the drop
# and hermes reading them, and config.yaml edits can still plant and
# enable a dashboard_auth plugin or configure a secret source
# (secrets.command) that emits the keys; those are config the user
# legitimately changes, so they stay unpinned.
#
# The settings are pinned through hermes' managed scope
# (./hermes-native/agents.nix, managedDirFor), so neither the dashboard nor
# the CLI can change them: dashboard.public_url (a non-loopback public URL
# turns the gate on even on the loopback bind, and is the only Host and WS
# Origin hermes accepts), the issuer and the client id. Scopes include
# offline_access: pocket-id issues a refresh token without it today
# (fosite RefreshTokenScopes = []), but offline_access is what the spec
# asks for, so sessions keep refreshing past the ID token's lifetime
# either way. Hermes accepts RS256 (pocket-id's only key) and ES*.
#
# nginx, per agent: Host and Origin unchanged; X-Forwarded-Proto, -For and
# Real-IP set by nginx (hermes runs uvicorn with proxy_headers in gated mode
# and trusts loopback, which is only nginx and the owner's own bridge here;
# its rate limits read the FIRST X-Forwarded-For hop, so the client's list
# is replaced, not appended to), X-Forwarded-Prefix and Forwarded cleared.
# Cookies: only hermes' own go in (./hermes-dashboard-cookies.js), so no
# other davhau.com site's login cookie reaches the agent. Set-Cookie passes
# (hermes' login needs it), with any Domain pinned to the agent's own host.
# The parent domain is not hermes.davhau.com on purpose: oauth2-proxy's
# login cookie carries Domain=<host> (./hermes-agents-serve.nix), and
# browsers would send it to an agent-controlled dashboard below it. Unknown
# names under agentDomain get a 404 from a server of their own, never a
# backend.
#
# Framing: every agent shares the registrable domain with every other
# agent and with the serve ports, so their pages count as same-site and a
# dashboard's Lax session cookies go along into an iframe. Each dashboard
# answers with `frame-ancestors 'self'` and X-Frame-Options SAMEORIGIN
# (unless hermes set its own), so no sibling can frame it and steer clicks
# into its terminal.
#
# Sign-in rate limit: hermes keeps at most 256 pending native logins, 8 per
# client address, for 10 minutes; an IPv6 client holds a whole /64 to
# rotate through. nginx limits /auth/login and /auth/native/authorize per
# agent to 6 a minute, burst 10, per IPv4 address or IPv6 /64
# (./hermes-dashboard-ratelimit.js). Clients spread over many /64s still
# get through.
#
# Residual, no fix here: cookie bombing. Any site under davhau.com can set
# enough Domain=davhau.com (or agents.davhau.com) cookies to make a
# browser's requests to a dashboard too large; nginx then answers 400 for
# that browser until the cookies expire. Only a registrable domain of its
# own (or a Public Suffix List entry) for the dashboards would end it.
#
# The old URL https://<host>/ stays behind oauth2-proxy (client `hermes`,
# group `hermes`, as the serve ports and the mail owner page) and only
# redirects: an account with one agent goes to that agent's dashboard,
# one with several gets a list of links, any other a 403. nginx learns the
# account after auth_request, which an `if` in the vhost would not see, so
# it asks a server on a unix socket that only nginx can reach.
#
# DNS: *.<agentDomain> A (publicIPv4: sgp's v4, forwarded here by
# ./ipv4-forward.nix) and AAAA (this host's networking.publicIPv6), kept by
# ./porkbun-records, plus TXT "v=spf1 -all": the wildcard makes every name
# below agentDomain exist, and none of them sends mail. No null MX
# (`MX 0 .`): ./porkbun-records has no MX priority. A wildcard does not
# shadow names that have records of their own (the mail names,
# ./agent-mail). TLS: one wildcard cert via porkbun DNS-01, so no agent
# name lands in the CT logs.
#
# Secrets (clan vars, root-owned, LoadCredential): the `hermes` client
# secret and each `hermes-<agent>` client secret are the shared oidc vars
# the oidc service declares; the cookie secret is per-machine
# (`hermes-oauth2-proxy`).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.hermesDashboard;
  hlib = import ./hermes-native/lib.nix { inherit lib; };
  portOf = hlib.dashboardPortFor;
  client = config.hyper.oidc.clients.${cfg.oidcClient};
  certName = "hermes-dashboards";
  frontSocket = "/run/nginx/hermes-front.sock";
  scopes = "openid profile email offline_access";

  clientIdOf = user: "hermes-${user}";
  # Agents per front-door account.
  agentsOf = lib.foldlAttrs (
    acc: user: u:
    acc // { ${u.account} = (acc.${u.account} or [ ]) ++ [ user ]; }
  ) { } cfg.users;
  # Reserved names under agentDomain that have records of their own.
  reserved = lib.optional (config.hyper.agentMail.enable or false) config.hyper.agentMail.hostname;
in
{
  imports = [
    ./oauth2-proxy-cookie-guard.nix
    ./porkbun-records
  ];

  options.hyper.hermesDashboard = {
    host = lib.mkOption {
      type = lib.types.str;
      description = "Front door behind oauth2-proxy: https://<host>/ redirects to the signed-in account's dashboard; the serve ports and the mail owner page hang below it.";
    };
    agentDomain = lib.mkOption {
      type = lib.types.str;
      description = "Parent domain of the dashboards: every agent's lives at https://<agent>.<agentDomain>/. Must not be <host> or below it.";
    };
    publicIPv4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "38.89.142.76";
      description = "Address of the *.<agentDomain> A record; its AAAA is networking.publicIPv6. Null: no DNS records are kept.";
    };
    oidcClient = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = "Id of the front door's oidc client (inventory, roles.client.machines.<host>.settings.clients).";
    };
    users = lib.mkOption {
      default = { };
      description = "Native hermes agents whose dashboard is published.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              account = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "pocket-id username that signs in to this dashboard (member of group hermes-<agent>) and owns the agent's private serve ports.";
              };
              publicUrl = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                default = "https://${name}.${cfg.agentDomain}";
                description = "The dashboard's public URL (hermes' dashboard.public_url).";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.users != { }) {
    assertions = [
      {
        assertion = config.hyper.oidc.clients ? ${cfg.oidcClient};
        message = "hyper.hermesDashboard: the inventory declares no oidc client `${cfg.oidcClient}` for this machine.";
      }
      {
        assertion = cfg.agentDomain != cfg.host && !lib.hasSuffix ".${cfg.host}" cfg.agentDomain;
        message = "hyper.hermesDashboard.agentDomain: must not be ${cfg.host} or below it, where oauth2-proxy's login cookie is sent.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: u:
        let
          c = config.hyper.oidc.clients.${clientIdOf user} or null;
        in
        [
          {
            assertion = config.hyper.hermesAgents ? ${user};
            message = "hyper.hermesDashboard.users.${user}: only an agent of hyper.hermesAgents has a host dashboard unit to publish.";
          }
          {
            assertion = builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" user != null;
            message = "hyper.hermesDashboard.users.${user}: the name is the dashboard's DNS label; use a-z, 0-9 and inner dashes.";
          }
          {
            assertion = !lib.elem "${user}.${cfg.agentDomain}" reserved;
            message = "hyper.hermesDashboard.users.${user}: ${user}.${cfg.agentDomain} is taken by another service.";
          }
          {
            assertion =
              c != null
              && !c.public
              && c.secretFile != null
              && c.pkce
              && c.requiresReauthentication
              && c.callbackURLs == [ "${u.publicUrl}/auth/callback" ]
              && c.allowedGroups == [ "hermes-${user}" ];
            message = "hyper.hermesDashboard.users.${user}: the inventory must declare the confidential oidc client ${clientIdOf user} for this machine, with pkce and requiresReauthentication, callback ${u.publicUrl}/auth/callback, group hermes-${user} (derived from machines/<machine>/hermes-dashboards.nix).";
          }
        ]
      ) cfg.users
    );

    # Managed (locked) .env keys of each agent: the gate and its provider.
    # The client secret goes to the owner's 0600 .env instead (secretEnv);
    # the managed dir is world-readable. The keys that would turn the gate
    # off or add another provider leave the .env before every dashboard
    # start (see the header).
    services.hermes-native.users = lib.mapAttrs (
      user: u:
      let
        secretFile = config.hyper.oidc.clients.${clientIdOf user}.secretFile or null;
      in
      {
        environment = {
          HERMES_DASHBOARD_PUBLIC_URL = u.publicUrl;
          HERMES_DASHBOARD_OIDC_ISSUER = config.hyper.oidc.issuer;
          HERMES_DASHBOARD_OIDC_CLIENT_ID = clientIdOf user;
          HERMES_DASHBOARD_OIDC_SCOPES = scopes;
        };
        secretEnv = lib.optionalAttrs (secretFile != null) {
          HERMES_DASHBOARD_OIDC_CLIENT_SECRET = toString secretFile;
        };
        dashboardDropEnv = [
          "HERMES_DESKTOP"
          "HERMES_DASHBOARD_SESSION_TOKEN"
          "HERMES_DASHBOARD_BASIC_AUTH_.*"
          "HERMES_DASHBOARD_OAUTH_CLIENT_ID"
          "HERMES_DASHBOARD_PORTAL_URL"
          "HERMES_DASHBOARD_DRAIN_SECRET"
        ];
      }
    ) cfg.users;
    # The config.yaml keys that register plugins/dashboard_auth's basic and
    # nous providers, pinned off (env wins over them, hence the drop
    # above). The drain provider has no config switch: its secret is
    # env-only. Neither the gateway nor hermes-desktop's `hermes serve`
    # reads them.
    services.hermes-native.settings.dashboard = {
      oauth.client_id = "";
      basic_auth = {
        username = "";
        password_hash = "";
        password = "";
      };
    };

    # Hosts under the same registrable domain (the agent slots) can toss
    # cookies onto this one: refuse a request carrying a login cookie name
    # twice (./oauth2-proxy-cookie-guard.nix).
    hyper.oauth2ProxyCookieGuard.virtualHosts = [ cfg.host ];

    clan.core.vars.generators = {
      hermes-oauth2-proxy = {
        files.cookie_secret = { };
        runtimeInputs = [
          pkgs.coreutils
          pkgs.openssl
        ];
        script = ''
          openssl rand -base64 32 | tr -d '\n' > "$out"/cookie_secret
        '';
      };
      # Shared var, same definition as ./dyndns-porkbun.nix; only DNS-01
      # reads it here.
      porkbun = {
        share = true;
        prompts.apikey.type = "hidden";
        prompts.apikey.persist = true;
        prompts.secretkey.type = "hidden";
        prompts.secretkey.persist = true;
      };
    }
    # A rotated client secret reaches the .env when the agent restarts, and
    # the dashboard reads it when it restarts after the agent.
    // lib.mapAttrs' (
      user: _:
      lib.nameValuePair "oidc-client-${clientIdOf user}" {
        files.secret.restartUnits = [
          "hermes-agent-${user}.service"
          "hermes-dashboard-${user}.service"
        ];
      }
    ) cfg.users;

    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      oidcIssuerUrl = config.hyper.oidc.issuer;
      clientID = client.clientId;
      clientSecretFile = client.secretFile;
      cookie.secretFile = config.clan.core.vars.generators.hermes-oauth2-proxy.files.cookie_secret.path;
      redirectURL = "https://${cfg.host}/oauth2/callback";
      email.domains = [ "*" ];
      setXauthrequest = true;
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      extraConfig = {
        # Accounts may have no email; identify them by username instead.
        oidc-email-claim = "preferred_username";
        insecure-oidc-allow-unverified-email = true;
        code-challenge-method = "S256";
        skip-provider-button = true;
      };
      nginx = {
        domain = cfg.host;
        virtualHosts.${cfg.host} = { };
      };
    };

    # OIDC discovery needs DNS for the issuer, and network-online.target
    # promises nothing where the wait-online services are masked (som). The
    # stock Restart=always at 100ms burnt the start limit within a second of
    # boot and left the front door down; retry every 5s, indefinitely, until
    # the issuer resolves and answers.
    systemd.services.oauth2-proxy = {
      serviceConfig.RestartSec = "5s";
      unitConfig.StartLimitIntervalSec = 0;
    };

    # nginx may dial the owner-gated root-held dashboard ports. -I puts
    # them before the REJECT ./hermes-native/firewall.nix appends for each
    # port.
    systemd.services.hermes-firewall.script = lib.mkAfter (
      lib.concatMapStrings (user: ''
        iptables -w -I ${hlib.chain} 1 -p tcp --dport ${toString (portOf user)} -m owner --uid-owner nginx -j RETURN
      '') (lib.attrNames cfg.users)
    );

    hyper.porkbunRecords.records = lib.mkIf (cfg.publicIPv4 != null) {
      "*.${cfg.agentDomain}" = {
        A = cfg.publicIPv4;
        TXT = "v=spf1 -all";
        AAAA.ipv6OnLink = {
          inherit (config.networking.publicIPv6) interface;
          suffix = config.networking.publicIPv6.token;
        };
      };
    };

    security.acme.certs.${certName} = {
      domain = "*.${cfg.agentDomain}";
      dnsProvider = "porkbun";
      # Not an enableACME cert, so the nginx module leaves the group alone.
      group = "nginx";
      credentialFiles = {
        PORKBUN_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.apikey.path;
        PORKBUN_SECRET_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.secretkey.path;
      };
      # som's upstream answers REFUSED for names that do not exist yet,
      # which ends lego's SOA walk (./agent-mail/default.nix).
      dnsResolver = "1.1.1.1:53";
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
    security.acme = {
      acceptTerms = true;
      defaults.email = "info@davhau.com";
    };
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      additionalModules = [ pkgs.nginxModules.njs ];
      appendHttpConfig = ''
        js_import hermes_dashboard_cookies from ${./hermes-dashboard-cookies.js};
        js_set $hermes_dashboard_cookie hermes_dashboard_cookies.hermesCookies;
        js_import hermes_dashboard_ratelimit from ${./hermes-dashboard-ratelimit.js};
        js_set $hermes_dashboard_client_net hermes_dashboard_ratelimit.clientNet;

        # Per agent and client network (the header).
        limit_req_zone "$hermes_dashboard_client_net $host" zone=hermes_dashboard_login:1m rate=6r/m;

        # Hermes' own X-Frame-Options, if it ever sends one, stays alone.
        map $upstream_http_x_frame_options $hermes_dashboard_frame_options {
          "" SAMEORIGIN;
          default "";
        }

        map $http_x_hermes_account $hermes_front_redirect {
          default "";
        ${lib.concatStrings (
          lib.mapAttrsToList (
            account: agents:
            lib.optionalString (lib.length agents == 1) ''
              "${account}" "${cfg.users.${lib.head agents}.publicUrl}/";
            ''
          ) agentsOf
        )}}

        map $http_x_hermes_account $hermes_front_choices {
          default "";
        ${lib.concatStrings (
          lib.mapAttrsToList (
            account: agents:
            lib.optionalString (lib.length agents > 1) ''
              "${account}" "Your hermes dashboards:\n${
                lib.concatMapStrings (a: "  ${cfg.users.${a}.publicUrl}/\\n") agents
              }";
            ''
          ) agentsOf
        )}}
      '';
      virtualHosts =
        {
          ${cfg.host} = {
            forceSSL = true;
            enableACME = true;
            locations."/" = {
              proxyPass = "http://unix:${frontSocket}:";
              recommendedProxySettings = false;
              extraConfig = ''
                auth_request_set $hermes_account $upstream_http_x_auth_request_preferred_username;
                proxy_set_header Host $host;
                proxy_set_header X-Hermes-Account $hermes_account;
                proxy_set_header Cookie "";
              '';
            };
          };
          # Answers the front door with the account nginx puts in the
          # header; nothing but nginx can connect (/run/nginx is 0750).
          hermes-front = {
            serverName = "_";
            listen = [ { addr = "unix:${frontSocket}"; } ];
            extraConfig = ''
              default_type text/plain;
              if ($hermes_front_redirect) {
                return 302 $hermes_front_redirect;
              }
              if ($hermes_front_choices) {
                return 200 $hermes_front_choices;
              }
              return 403 "No hermes dashboard for this account.\n";
            '';
          };
          # Names under agentDomain that are no dashboard, and the default
          # server, so a request for an unknown Host on this host never
          # reaches a backend either.
          hermes-dashboard = {
            serverName = "*.${cfg.agentDomain}";
            default = true;
            forceSSL = true;
            useACMEHost = certName;
            locations."/".return = "404";
          };
        }
        // lib.mapAttrs' (
          user: u:
          let
            location = {
              proxyPass = "http://127.0.0.1:${toString (portOf user)}";
              # /api/ws, /api/pty, /api/events and the kanban feed are
              # long-lived websockets / SSE streams that sit idle far
              # longer than 60s.
              proxyWebsockets = true;
              # recommendedProxySettings appends to the client's
              # X-Forwarded-For; hermes reads its first hop.
              recommendedProxySettings = false;
              extraConfig = ''
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $remote_addr;
                proxy_set_header X-Forwarded-Proto https;
                proxy_set_header X-Forwarded-Host $host;
                proxy_set_header X-Forwarded-Prefix "";
                proxy_set_header Forwarded "";
                proxy_set_header Cookie $hermes_dashboard_cookie;
                proxy_cookie_domain ~.+ $host;
                proxy_read_timeout 1h;
                proxy_send_timeout 1h;
                client_max_body_size 256m;
              '';
            };
            # The two that start a sign-in (the header).
            signIn = location // {
              extraConfig = location.extraConfig + ''
                limit_req zone=hermes_dashboard_login burst=10 nodelay;
                limit_req_status 429;
              '';
            };
          in
          lib.nameValuePair "hermes-dashboard-${user}" {
            serverName = "${user}.${cfg.agentDomain}";
            forceSSL = true;
            useACMEHost = certName;
            # Server level, so every location inherits them: none adds a
            # header of its own, which would drop these (nginx add_header).
            extraConfig = ''
              add_header Content-Security-Policy "frame-ancestors 'self'" always;
              add_header X-Frame-Options $hermes_dashboard_frame_options always;
            '';
            locations."/" = location;
            locations."= /auth/login" = signIn;
            locations."= /auth/native/authorize" = signIn;
          }
        ) cfg.users;
    };
  };
}
