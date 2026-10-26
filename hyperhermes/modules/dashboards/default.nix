# Every agent's hermes web dashboard at its own host name,
# <agent>.<domain> (exposure), with hermes' own OIDC login (sso) -> nginx
# -> the root-held dashboard port of that agent (core's forwards), which
# bridges to the agent's loopback backend after checking the backend's
# owner. Same routing in both exposure modes; only the scheme, the port and
# the certificates differ.
#
# <domain> carries everything an agent can make a browser render (here and
# in the features that publish more per agent); the deployment keeps what
# it serves itself (its identity provider, the front door, ...) on a site
# of its own. Browsers treat every name under one registrable domain as one
# site, so an agent's page under the deployment's own domain could forge
# requests carrying the visitor's logins there, and plant or flood cookies.
# Under <domain> it can do none of that to the deployment's site.
#
# Between agents (all of them share the site <domain>):
#   - logins are host-only: hermes' `__Host-` session cookies here (over
#     HTTPS); nothing of ours ever sets a cookie with Domain=<domain> or
#     Domain=<agent>.<domain>,
#   - one OIDC client per agent (ID tokens are aud-bound to it), admitting
#     only the group hermes-<agent>: the issuer may enforce that itself, and
#     hermes does (HERMES_DASHBOARD_OIDC_ALLOWED_GROUPS, core's
#     hermes-dashboard-oidc-allowed-groups patch) on the ID token's verified
#     `groups` claim at sign-in, at every refresh and on every request,
#   - a Fetch Metadata gate on every dashboard (exposure): requests a
#     browser sends from another origin are refused unless they are
#     top-level GET navigations,
#   - no framing (below).
# Residual: cookie bombing within <domain> (a page of one agent sets enough
# Domain=<domain> cookies to make a browser's requests to every other
# agent's hosts too large: 400 until they expire), apps with side effects
# on GET reached by a link, browsers without Fetch Metadata, and what
# timing or error pages leak about the visitor's sign-in state. A Public
# Suffix List entry for <domain> would make every <agent>.<domain> a site
# of its own and close the first and the CSRF exposure; nothing else here
# would need to change, which is why other features' hosts sit below the
# agent's name.
#
# The login: the dashboard runs gated, with its bundled `self_hosted` OIDC
# provider against sso.issuer. Each agent has its own CONFIDENTIAL client
# `hermes-<agent>` (PKCE plus a client secret), callback
# <origin of agent.domain>/auth/callback (../../lib/sso.nix). The agent is
# the relying party, so it may hold its own client's secret; what the
# secret stops is everyone else using that client id. An issuer that lets
# any client run the device-code grant (pocket-id) would otherwise let
# anyone start one for hermes-<agent>, have a member approve the
# genuine-looking code page and walk away with that agent's ID and refresh
# tokens. The secret (sso.clients.hermes-<agent>.secretFile) rides a
# systemd credential into the agent's unit and lands in the owner's 0600
# .env as HERMES_DASHBOARD_OIDC_CLIENT_SECRET (core's secretEnv), never in
# the store or the managed dir; hermes sends it with HTTP Basic when the
# issuer's discovery offers it.
#
# Sign-in prompts: the browser flow rides the issuer's session, so one
# sign-in at the front door (or anywhere else at the issuer) opens every
# dashboard the account may use without asking again. That is safe because
# its code only ever goes to the dashboard's own registered callback. The
# native-app flow is different: hermes accepts any http://127.0.0.1:<port>
# redirect for it, so a program on the user's device listening there could
# start a login in the browser and collect it silently. nginx therefore
# adds prompt=login to the issuer redirect /auth/native/authorize answers
# with, and the issuer asks again on every app sign-in. The broker state
# rides in a `__Host-` cookie of that same browser response, so taking the
# redirect without the prompt and replaying it elsewhere breaks the
# callback. Browsers and the Hermes Mobile app (RFC 8252 native PKCE,
# brokered by the dashboard's /auth/native/*) sign in the same way.
#
# Trust: the agent behind a dashboard is untrusted and IS the relying party.
# That is fine here because everything that would make its login worth
# stealing is per agent: the client (ID tokens are aud-bound to
# hermes-<agent>; hermes verifies signature, iss and aud), the hostname
# (its `__Host-` session cookies reach no other host), the group check
# (only that agent's accounts get a session at all), and the credentials
# (bound to the issuer's origin, never to the dashboard's). The agent can
# switch its own gate off; it could already publish itself through an
# outbound tunnel, so that opens nothing new. Kept out of reach is doing so
# with a plain edit of its env files (a prompt-injected write to .env or
# .op.env, no code run): before every dashboard start the keys that turn
# the gate off or add another way in are dropped from both
# (dashboardDropEnv below; from hermes 345cd2b: web_server.py exempts a
# loopback backend with HERMES_DESKTOP=1 plus a
# HERMES_DASHBOARD_SESSION_TOKEN, the basic, nous and drain providers of
# plugins/dashboard_auth register from their env keys, and
# HERMES_MANAGED_DIR would move the managed scope), and the config keys
# that register the basic or nous provider are pinned empty. Not pinned in
# the managed .env: hermes-desktop's `hermes serve` for an agent gets
# HERMES_DESKTOP=1 in its process env, and the managed .env would override
# it. What remains is the residual above: an agent process can rewrite the
# files between the drop and hermes reading them, and config.yaml edits can
# still plant and enable a dashboard_auth plugin or configure a secret
# source (secrets.command) that emits the keys; those are config the user
# legitimately changes, so they stay unpinned.
#
# The settings are pinned through hermes' managed scope (core,
# managedDirFor), so neither the dashboard nor the CLI can change them:
# dashboard.public_url (a non-loopback public URL turns the gate on even on
# the loopback bind, and is the only Host and WS Origin hermes accepts),
# the issuer, the client id and the allowed group. Scopes: `groups` puts
# the group claim the check reads into the ID token (pocket-id and dex emit
# it only for that scope); offline_access is what the spec asks for to get
# a refresh token, so sessions keep refreshing past the ID token's
# lifetime. Hermes accepts RS256 and ES*.
#
# nginx, per agent: Host and Origin unchanged; X-Forwarded-Proto, -For and
# Real-IP set by nginx (hermes runs uvicorn with proxy_headers in gated mode
# and trusts loopback, which is only nginx and the owner's own bridge here;
# its rate limits read the FIRST X-Forwarded-For hop, so the client's list
# is replaced, not appended to), X-Forwarded-Prefix and Forwarded cleared.
# Cookies: only hermes' own go in (./cookies.js), so no other agent's
# cookies reach this one. Set-Cookie passes (hermes' login needs it), with
# any Domain pinned to the agent's own host. Unknown names under <domain>
# get a 404 from exposure's catch-all server, never a backend.
#
# Cross-origin requests (exposure's Fetch Metadata gate): what the
# dashboard itself does is same-origin (the SPA's API calls, its
# websockets, /api/files/download links); the browser sign-in comes back
# from the issuer as a cross-site GET navigation; the app's native sign-in
# runs in a Custom Tab (Sec-Fetch-Site none, then navigations) and its API
# calls come from OkHttp without Sec-Fetch-* headers. All of that passes;
# another agent's page posting or fetching here does not.
#
# Framing: every agent shares the site with every other agent, so their
# pages count as same-site and a dashboard's Lax session cookies would go
# along into an iframe. Each dashboard answers with `frame-ancestors
# 'self'` and X-Frame-Options SAMEORIGIN (unless hermes set its own), so no
# sibling can frame it and steer clicks into its terminal.
#
# Sign-in rate limit: hermes keeps at most 256 pending native logins, 8 per
# client address, for 10 minutes; an IPv6 client holds a whole /64 to
# rotate through. nginx limits /auth/login and /auth/native/authorize per
# agent to 6 a minute, burst 10, per IPv4 address or IPv6 /64
# (./ratelimit.js). Clients spread over many /64s still get through.
#
# Request limits: nginx opens a connection to the agent's socket per
# request, and each one runs a bridge process (core's forwards, whose
# sockets carry no trigger limit, so a flood never stops them). Per agent
# host (dashboards here; features publishing more hosts per agent use the
# same zones) and client network as above, nginx passes 50 requests a
# second after a burst of 500 and at most 128 requests in flight
# (websockets included; HTTP/2's 128 streams per connection), then answers
# 429. The sockets' poll limit (2000 accepts per 2s) holds the bursts of
# three client networks at once. A single page load of a dev server with
# hundreds of modules fits the burst; one client network cannot take a
# socket's whole capacity. Per host, all client networks together get at
# most 384 requests in flight, below the socket's 512 bridges, so the
# owner's own dialers always find a slot. Residual: clients spread over
# four or more networks can still fill those 384 and the host's other
# visitors get 429 until their requests end; the agent, its other hosts
# and the other agents stay up.
#
# The front door (sso.frontDoor.host, behind sso's oauth2-proxy) only
# redirects: an account with one agent goes to that agent's dashboard, one
# with several gets a list of links, any other a 403. <front door>/app is
# the phone setup page: the signed-in account's dashboard address(es),
# links to the apps (Hermes Mobile on Android, Hermes Conduit on iPhone)
# and a conduit://connect link that fills the address in Conduit. One
# static page per account, built here from Nix values only. nginx learns
# the account after auth_request, which an `if` in the vhost would not
# see, so it asks a server on a unix socket that only nginx can reach.
#
# Transition (legacyDomain, public mode): https://<agent>.<legacyDomain>/
# answers 301 to the dashboard, path and query kept, on port 80 as on 443,
# and serves nothing else; drop it once the old links are gone. Its records
# and certificate stay until then. Let's Encrypt follows redirects in
# HTTP-01, so a challenge path that redirected into the agent's dashboard
# would get the agent a certificate for a name of the deployment's site:
# /.well-known/acme-challenge/ answers 404 there, and CAA on legacyDomain
# (exposure.acme.caa) lets the CA issue by DNS-01 only, which needs the DNS
# credentials only root holds.
#
# DNS (public mode, exposure.dnsRecords): each dashboard name
# <agent>.<domain> gets the wildcard's records explicitly: names exist
# below it in other features (*.<agent>.<domain>, slot.<agent>.<domain>),
# which makes it an empty non-terminal that *.<domain> does not answer for
# under RFC 4592. TLS: exposure's wildcard certificate of *.<domain>, so no
# agent name lands in the CT logs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.dashboards;
  exposure = config.services.hyperhermes.exposure;
  sso = config.services.hyperhermes.sso;
  hlib = import ../../lib/core.nix { inherit lib; };
  ssoLib = import ../../lib/sso.nix { inherit lib; };
  public = exposure.mode == "public";
  portOf = hlib.dashboardPortFor;
  agents = config.services.hyperhermes.agents;
  names = lib.attrNames agents;
  frontDoor = sso.frontDoor.host;
  legacyCert = "hermes-dashboards";
  frontSocket = "/run/nginx/hermes-front.sock";
  scopes = "openid profile email groups offline_access";

  vhostOf = agent: "hermes-dashboard-${agent}";
  hostOf = agent: "${agent}.${exposure.domain}";
  urlOf = agent: exposure.urlOf (hostOf agent);
  # Agents per front-door account.
  agentsOf = lib.foldlAttrs (
    acc: agent: account:
    acc // { ${account} = (acc.${account} or [ ]) ++ [ agent ]; }
  ) { } (lib.filterAttrs (agent: _: agents ? ${agent}) sso.accounts);
  # nginx vhosts other than the dashboard's own that answer <agent>'s name.
  otherVhostsFor =
    agent:
    lib.attrNames (
      lib.filterAttrs (
        name: v:
        name != vhostOf agent
        && lib.elem (hostOf agent) (
          [ (if v.serverName != null then v.serverName else name) ] ++ v.serverAliases
        )
      ) config.services.nginx.virtualHosts
    );
  frontLocation = {
    proxyPass = "http://unix:${frontSocket}:";
    recommendedProxySettings = false;
    extraConfig = ''
      auth_request_set $hermes_account $upstream_http_x_auth_request_preferred_username;
      proxy_set_header Host $host;
      proxy_set_header X-Hermes-Account $hermes_account;
      proxy_set_header Cookie "";
    '';
  };
  frontMap = variable: f: ''
    map $http_x_hermes_account ${variable} {
      default "";
    ${
      lib.concatStrings (
        lib.mapAttrsToList (
          account: owned:
          let
            value = f owned;
          in
          lib.optionalString (value != null) ''
            "${account}" "${value}";
          ''
        ) agentsOf
      )
    }}
  '';
  # The phone setup page of one account (the header). Only Nix values go
  # in: agent names are DNS labels (asserted), so nothing needs escaping
  # beyond the URL parameter.
  appPage =
    account: owned:
    let
      entry =
        a:
        let
          url = urlOf a;
          param = lib.replaceStrings [ ":" "/" ] [ "%3A" "%2F" ] url;
        in
        ''
          <p class="addr">${url}</p>
          <p><a class="btn" href="conduit://connect?url=${param}">iPhone: open in Hermes Conduit</a></p>
        '';
    in
    pkgs.writeText "hermes-app-${account}.html" ''
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Hermes on your phone</title>
      <style>
      body{font:17px/1.5 system-ui,sans-serif;max-width:34rem;margin:2rem auto;padding:0 1rem}
      .addr{font:600 1.1rem monospace;user-select:all;-webkit-user-select:all;padding:.6rem;border:1px solid #888;border-radius:.4rem;word-break:break-all}
      .btn{display:inline-block;padding:.6rem 1rem;border-radius:.4rem;background:#3366cc;color:#fff;text-decoration:none}
      li{margin:.4rem 0}
      </style></head><body>
      <h1>Hermes on your phone</h1>
      <p>Your assistant's address${lib.optionalString (lib.length owned > 1) "es"}:</p>
      ${lib.concatMapStrings entry owned}
      <h2>Android</h2>
      <ol>
      <li>Install <b>Hermes Mobile</b> from <a href="https://f-droid.org/packages/com.m57.hermescontrol/">F-Droid</a>
      or <a href="https://github.com/Hy4ri/hermes-mobile/releases/latest">GitHub</a>.</li>
      <li>Open it, tap <b>Sign in</b> and enter the address above (tap it to select, then copy).</li>
      <li>Tap the browser sign-in and confirm with your passkey.</li>
      </ol>
      <h2>iPhone</h2>
      <ol>
      <li>Install <a href="https://apps.apple.com/us/app/hermes-conduit/id6790977764"><b>Hermes Conduit</b></a> from the App Store.</li>
      <li>Tap <b>iPhone: open in Hermes Conduit</b> above, then <b>Sign in</b>, and confirm with your passkey.</li>
      </ol>
      <p>Reading this on a computer? Open ${exposure.urlOf frontDoor}/app on your phone instead.</p>
      </body></html>
    '';
  appPages = pkgs.linkFarm "hermes-app-pages" (
    lib.mapAttrsToList (account: owned: {
      name = "${account}.html";
      path = appPage account owned;
    }) agentsOf
  );
in
{
  options.services.hyperhermes.dashboards = {
    enable = lib.mkEnableOption "every agent's web dashboard at <agent>.<domain>, behind hermes' OIDC login";

    legacyDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "agents.example.com";
      description = "Public mode, transition: the dashboards' old parent domain. https://<agent>.<this>/ answers 301 to the dashboard, nothing else. Keeps its wildcard records and certificate.";
    };
  };

  # Per agent: the dashboard's URL, and its login as managed (locked) .env
  # keys: the gate and its provider. The client secret goes to the owner's
  # 0600 .env instead (secretEnv); the managed dir is world-readable. The
  # keys that would turn the gate off or add another provider leave the
  # .env before every dashboard start (the header).
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options.dashboard.url = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = urlOf name;
            defaultText = lib.literalMD "the origin of `<agent>.<exposure.domain>`";
            description = "The dashboard's URL (hermes' dashboard.public_url).";
          };

          config = lib.mkIf cfg.enable {
            environment = lib.mapAttrs (_: lib.mkDefault) {
              HERMES_DASHBOARD_PUBLIC_URL = urlOf name;
              HERMES_DASHBOARD_OIDC_ISSUER = sso.issuer;
              HERMES_DASHBOARD_OIDC_CLIENT_ID = ssoLib.clientIdOf name;
              HERMES_DASHBOARD_OIDC_SCOPES = scopes;
              HERMES_DASHBOARD_OIDC_ALLOWED_GROUPS = ssoLib.groupOf name;
            };
            secretEnv.HERMES_DASHBOARD_OIDC_CLIENT_SECRET = sso.clients.${ssoLib.clientIdOf name}.secretFile;
            dashboardDropEnv = [
              "HERMES_DESKTOP"
              "HERMES_DASHBOARD_SESSION_TOKEN"
              "HERMES_DASHBOARD_BASIC_AUTH_.*"
              "HERMES_DASHBOARD_OAUTH_CLIENT_ID"
              "HERMES_DASHBOARD_PORTAL_URL"
              "HERMES_DASHBOARD_DRAIN_SECRET"
            ];
          };
        }
      )
    );
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = sso.enable;
            message = "services.hyperhermes.dashboards needs services.hyperhermes.sso.enable.";
          }
          {
            assertion = cfg.legacyDomain != null -> public;
            message = "services.hyperhermes.dashboards.legacyDomain needs exposure.mode = public.";
          }
        ]
        ++ lib.concatMap (
          agent:
          let
            others = otherVhostsFor agent;
          in
          [
            {
              assertion = builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" agent != null;
              message = "services.hyperhermes.agents.${agent}: the name is the dashboard's DNS label; use a-z, 0-9 and inner dashes, at most 63.";
            }
            {
              assertion = builtins.match "[0-9]+" agent == null && agent != "slot";
              message = "services.hyperhermes.agents.${agent}: all-digit labels are serve ports and `slot` is the agent slot's label; pick another name.";
            }
            {
              assertion = others == [ ];
              message = "services.hyperhermes.dashboards: ${hostOf agent} is taken by nginx vhosts ${toString others}.";
            }
          ]
        ) names;

        # The config.yaml keys that register plugins/dashboard_auth's basic
        # and nous providers, pinned off (env wins over them, hence the drop
        # above). The drain provider has no config switch: its secret is
        # env-only. Neither the gateway nor hermes-desktop's `hermes serve`
        # reads them.
        services.hyperhermes.settings.dashboard = {
          oauth.client_id = "";
          basic_auth = {
            username = "";
            password_hash = "";
            password = "";
          };
        };

        # Cross-origin requests (the header): every dashboard, and the front
        # door, whose own flow is navigations only.
        services.hyperhermes.exposure.fetchMetadataGate.virtualHosts =
          lib.optional (frontDoor != null) frontDoor ++ map vhostOf names;

        # nginx may dial the owner-gated root-held dashboard ports. -I puts
        # them before the REJECT core's firewall appends for each port.
        systemd.services.hermes-firewall.script = lib.mkAfter (
          lib.concatMapStrings (agent: ''
            iptables -w -I ${hlib.chain} 1 -p tcp --dport ${toString (portOf agent)} -m owner --uid-owner nginx -j RETURN
          '') names
        );

        services.nginx = {
          enable = true;
          additionalModules = [ pkgs.nginxModules.njs ];
          appendHttpConfig = ''
            js_import hermes_dashboard_cookies from ${./cookies.js};
            js_set $hermes_dashboard_cookie hermes_dashboard_cookies.hermesCookies;
            js_import hermes_dashboard_ratelimit from ${./ratelimit.js};
            js_set $hermes_dashboard_client_net hermes_dashboard_ratelimit.clientNet;

            # Per agent and client network (the header).
            limit_req_zone "$hermes_dashboard_client_net $host" zone=hermes_dashboard_login:1m rate=6r/m;
            # Every request to an agent's host, a dashboard or another
            # feature's per-agent host, per host and client network (the
            # header). 10m holds some 80000 keys.
            limit_req_zone "$hermes_dashboard_client_net $host" zone=hermes_agent_requests:10m rate=50r/s;
            limit_conn_zone "$hermes_dashboard_client_net $host" zone=hermes_agent_conns:10m;
            # Per host alone, every client network together (the header).
            limit_conn_zone $host zone=hermes_agent_host_conns:1m;

            # Hermes' own X-Frame-Options, if it ever sends one, stays alone.
            map $upstream_http_x_frame_options $hermes_dashboard_frame_options {
              "" SAMEORIGIN;
              default "";
            }
          ''
          + lib.optionalString (cfg.legacyDomain != null) ''
            map $host $hermes_dashboard_legacy {
              default "";
            ${
              lib.concatMapStrings (agent: ''
                "${agent}.${cfg.legacyDomain}" "${urlOf agent}";
              '') names
            }}
          '';
          virtualHosts = lib.listToAttrs (
            map (
              agent:
              let
                location = {
                  proxyPass = "http://127.0.0.1:${toString (portOf agent)}";
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
                    proxy_set_header X-Forwarded-Proto ${if public then "https" else "http"};
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
              lib.nameValuePair (vhostOf agent) (
                exposure.virtualHost exposure.certName
                // {
                  serverName = hostOf agent;
                  # Server level, so every location inherits them: none adds
                  # a header of its own, which would drop these (nginx
                  # add_header). The sign-in locations' own limit_req
                  # replaces the request limit there (nginx inherits
                  # limit_req only into a level without one); the stricter
                  # sign-in limit holds.
                  extraConfig = ''
                    add_header Content-Security-Policy "frame-ancestors 'self'" always;
                    add_header X-Frame-Options $hermes_dashboard_frame_options always;
                    limit_req zone=hermes_agent_requests burst=500 nodelay;
                    limit_conn hermes_agent_conns 128;
                    limit_conn hermes_agent_host_conns 384;
                    limit_req_status 429;
                    limit_conn_status 429;
                  '';
                  locations."/" = location;
                  locations."= /auth/login" = signIn;
                  # The app's sign-in always asks again (the header).
                  locations."= /auth/native/authorize" = signIn // {
                    extraConfig = signIn.extraConfig + ''
                      proxy_redirect "~^(${lib.escapeRegex sso.issuer}/authorize\?.*)$" "$1&prompt=login";
                    '';
                  };
                }
              )
            ) names
          );
        };
      }

      (lib.mkIf (frontDoor != null) {
        services.nginx.appendHttpConfig = ''
          ${frontMap "$hermes_front_redirect" (
            owned: if lib.length owned == 1 then "${urlOf (lib.head owned)}/" else null
          )}
          ${frontMap "$hermes_front_choices" (
            owned:
            if lib.length owned > 1 then
              "Your hermes dashboards:\\n${lib.concatMapStrings (a: "  ${urlOf a}/\\n") owned}"
            else
              null
          )}
          # The account's own page file; unknown accounts map to nothing, so
          # the header never reaches a file path.
          map $http_x_hermes_account $hermes_front_app {
            default "";
          ${
            lib.concatMapStrings (account: ''
              "${account}" "${account}.html";
            '') (lib.attrNames agentsOf)
          }}
        '';
        services.nginx.virtualHosts = {
          ${frontDoor} = {
            locations."/" = frontLocation;
            locations."= /app" = frontLocation;
          };
          # Answers the front door with the account nginx puts in the
          # header; nothing but nginx can connect (/run/nginx is 0750).
          hermes-front = {
            serverName = "_";
            listen = [ { addr = "unix:${frontSocket}"; } ];
            extraConfig = ''
              default_type text/plain;
              add_header X-Content-Type-Options nosniff always;
            '';
            locations."= /app".extraConfig = ''
              if ($hermes_front_app = "") {
                return 403 "No hermes dashboard for this account.\n";
              }
              default_type text/html;
              add_header X-Content-Type-Options nosniff always;
              add_header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" always;
              alias ${appPages}/$hermes_front_app;
            '';
            locations."/".extraConfig = ''
              if ($hermes_front_redirect) {
                return 302 $hermes_front_redirect;
              }
              if ($hermes_front_choices) {
                return 200 $hermes_front_choices;
              }
              return 403 "No hermes dashboard for this account.\n";
            '';
          };
        };
      })

      (lib.mkIf public {
        services.hyperhermes.exposure.records = lib.mkIf (exposure.hostRecords != { }) (
          lib.genAttrs (map hostOf names) (_: exposure.hostRecords)
        );
      })

      (lib.mkIf (cfg.legacyDomain != null) {
        services.hyperhermes.exposure.records =
          lib.optionalAttrs (exposure.hostRecords != { }) {
            "*.${cfg.legacyDomain}" = removeAttrs exposure.hostRecords [ "TXT" ];
          }
          // lib.optionalAttrs (exposure.acme.caa != null) {
            ${cfg.legacyDomain}.CAA = exposure.acme.caa;
          };
        security.acme.certs.${legacyCert} = exposure.acmeCert "*.${cfg.legacyDomain}";
        # Transition only: 301 to the new name, never a backend, on 80 and
        # 443 alike; no ACME challenge answer that could follow it (the
        # header).
        services.nginx.virtualHosts.hermes-dashboard-legacy = {
          serverName = "*.${cfg.legacyDomain}";
          addSSL = true;
          useACMEHost = legacyCert;
          locations."^~ /.well-known/acme-challenge/".return = "404";
          locations."/".extraConfig = ''
            if ($hermes_dashboard_legacy = "") {
              return 404;
            }
            return 301 $hermes_dashboard_legacy$request_uri;
          '';
        };
      })
    ]
  );
}
