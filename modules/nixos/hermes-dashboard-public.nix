# Public web dashboards for native hermes agents, one hostname per agent:
# https://<agent>.<agentDomain>/ (on som <agent>.davhau.fyi) -> nginx -> the
# root-held dashboard port of that agent (./hermes-native/forwards.nix),
# which bridges to the agent's loopback backend after checking the
# backend's owner.
#
# Two sites: agentDomain (davhau.fyi) carries everything an agent can make
# a browser render, here and in ./hermes-agents-serve.nix and
# ./agent-slots.nix; davhau.com keeps only what we serve ourselves (pocket-id,
# the front door <host>, the mail owner page, Nextcloud, ...). Browsers
# treat every name under one registrable domain as one site, so an agent's
# page under davhau.com could forge requests carrying the visitor's
# davhau.com logins, and plant or flood cookies there. Under davhau.fyi it
# can do none of that to davhau.com.
#
# Between agents (all of them share the site davhau.fyi):
#   - logins are host-only: hermes' `__Host-` session cookies here, the
#     serve ports' `__Host-` oauth2-proxy cookie per port host; nothing of
#     ours ever sets a cookie with Domain=<agentDomain> or
#     Domain=<agent>.<agentDomain>,
#   - one OIDC client per agent (ID tokens are aud-bound to it),
#   - a Fetch Metadata gate on every dashboard and private serve port
#     (./fetch-metadata-gate.nix): requests a browser sends from another
#     origin are refused unless they are top-level GET navigations,
#   - no framing (below).
# Residual: cookie bombing within davhau.fyi (a page of one agent sets
# enough Domain=davhau.fyi cookies to make a browser's requests to every
# other agent's hosts too large: 400 until they expire), apps with side
# effects on GET reached by a link, browsers without Fetch Metadata, and
# what timing or error pages leak about the visitor's sign-in state. A
# Public Suffix List entry for davhau.fyi would make every
# <agent>.davhau.fyi a site of its own and close the first and the CSRF
# exposure; nothing else here would need to change, which is why the serve
# ports and the slot sit below the agent's name.
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
# which pocket-id's discovery offers.
#
# Sign-in prompts: the browser flow rides the pocket-id session, so one
# passkey at the front door (or anywhere else at pocket-id) opens every
# dashboard the account may use without asking again. That is safe because
# its code only ever goes to the dashboard's own registered callback. The
# native-app flow is different: hermes accepts any http://127.0.0.1:<port>
# redirect for it, so a program on the user's device listening there could
# start a login in the browser and collect it silently. nginx therefore
# adds prompt=login to the pocket-id redirect /auth/native/authorize
# answers with, and pocket-id asks for the passkey on every app sign-in.
# The broker state rides in a `__Host-` cookie of that same browser
# response, so taking the redirect without the prompt and replaying it
# elsewhere breaks the callback.
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
# (its `__Host-` session cookies reach no other host), pocket-id's group
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
#
# nginx, per agent: Host and Origin unchanged; X-Forwarded-Proto, -For and
# Real-IP set by nginx (hermes runs uvicorn with proxy_headers in gated mode
# and trusts loopback, which is only nginx and the owner's own bridge here;
# its rate limits read the FIRST X-Forwarded-For hop, so the client's list
# is replaced, not appended to), X-Forwarded-Prefix and Forwarded cleared.
# Cookies: only hermes' own go in (./hermes-dashboard-cookies.js), so no
# other agent's cookies reach this one. Set-Cookie passes (hermes' login
# needs it), with any Domain pinned to the agent's own host. Unknown names
# under agentDomain get a 404 from a server of their own, never a backend.
#
# Cross-origin requests (./fetch-metadata-gate.nix): what the dashboard
# itself does is same-origin (the SPA's API calls, its websockets,
# /api/files/download links); the browser sign-in comes back from
# pocket-id as a cross-site GET navigation; the app's native sign-in runs
# in a Custom Tab (Sec-Fetch-Site none, then navigations) and its API
# calls come from OkHttp without Sec-Fetch-* headers. All of that passes;
# another agent's page posting or fetching here does not.
#
# Framing: every agent shares the site with every other agent and with the
# serve ports, so their pages count as same-site and a dashboard's Lax
# session cookies would go along into an iframe. Each dashboard answers
# with `frame-ancestors 'self'` and X-Frame-Options SAMEORIGIN (unless
# hermes set its own), so no sibling can frame it and steer clicks into
# its terminal.
#
# Sign-in rate limit: hermes keeps at most 256 pending native logins, 8 per
# client address, for 10 minutes; an IPv6 client holds a whole /64 to
# rotate through. nginx limits /auth/login and /auth/native/authorize per
# agent to 6 a minute, burst 10, per IPv4 address or IPv6 /64
# (./hermes-dashboard-ratelimit.js). Clients spread over many /64s still
# get through.
#
# Request limits: nginx opens a connection to the agent's socket per
# request, and each one runs a bridge process (./hermes-native/forwards.nix,
# whose sockets carry no trigger limit, so a flood never stops them). Per
# agent host (dashboards here, serve ports in ./hermes-agents-serve.nix)
# and client network as above, nginx passes 50 requests a second after a
# burst of 500 and at most 128 requests in flight (websockets included;
# HTTP/2's 128 streams per connection), then answers 429. The sockets'
# poll limit (2000 accepts per 2s) holds the bursts of three client
# networks at once. A single page load of a dev server with hundreds of
# modules fits the burst; one client network cannot take a socket's whole
# capacity. Per host, all client networks together get at most 384
# requests in flight, below the socket's 512 bridges, so the owner's own
# dialers always find a slot. Residual: clients spread over four or more
# networks can still fill those 384 and the host's other visitors get 429
# until their requests end; the agent, its other hosts and the other
# agents stay up.
#
# The front door https://<host>/ (hermes.davhau.com) stays behind
# oauth2-proxy (client `hermes`, group `hermes`, as the mail owner page)
# and only redirects: an account with one agent goes to that agent's
# dashboard, one with several gets a list of links, any other a 403.
# https://<host>/app is the phone setup page: the signed-in account's
# dashboard address(es), links to the apps (Hermes Mobile on Android, Hermes
# Conduit on iPhone) and a conduit://connect link that fills the address in
# Conduit. One static page per account, built here from Nix values only.
# nginx learns the account after auth_request, which an `if` in the vhost
# would not see, so it asks a server on a unix socket that only nginx can
# reach. The login
# cookie is `__Host-hermes`, host-only: no other davhau.com name can set or
# overwrite it, and it reaches no agent-controlled host. oauth2-proxy
# listens on a unix socket systemd (root) holds for the whole uptime
# (`http-address=fd:3`), root:nginx 0660: no agent talks to it past nginx
# or takes its address while it is down, as it could a loopback port, and
# then answer nginx's auth_request with an account of its choosing. TLS is
# DNS-01 like every name below it (CAA, below).
#
# Transition (legacy.agentDomain): https://<agent>.<legacy.agentDomain>/
# (the old agents.davhau.com names) answers 301 to the dashboard, path and
# query kept, on port 80 as on 443, and serves nothing else; drop it once
# the old links are gone. Its records and certificate stay until then.
# Let's Encrypt follows redirects in HTTP-01, so a challenge path that
# redirected into the agent's dashboard would get the agent a certificate
# for a davhau.com name: /.well-known/acme-challenge/ answers 404 there,
# and CAA on legacy.agentDomain and on <host> (covering the serve ports'
# old names, the mail owner page and the front door) lets Let's Encrypt
# issue by DNS-01 only, which needs the porkbun key only root holds. The
# mail domain's MX certificate below legacy.agentDomain is DNS-01 already
# (./agent-mail/default.nix).
#
# DNS: *.<agentDomain> A (publicIPv4: sgp's v4, forwarded here by
# ./ipv4-forward.nix) and AAAA (this host's networking.publicIPv6), kept by
# ./porkbun-records. No TXT on the wildcards: a wildcard TXT also answers
# _acme-challenge.<name> until lego creates that record, resolvers cache
# that answer, and the DNS-01 propagation check then times out. Names below
# agentDomain send no mail: the _dmarc record's sp=reject covers them, the
# apex and the dashboard names get "v=spf1 -all". No null MX (`MX 0 .`):
# ./porkbun-records has no MX priority. A wildcard does not shadow names
# that have records of their own. Each dashboard name <agent>.<agentDomain>
# gets the same records explicitly: names exist below it
# (*.<agent>.<agentDomain>,
# slot.<agent>.<agentDomain>), which makes it an empty non-terminal that
# *.<agentDomain> does not answer for under RFC 4592 (porkbun answers it
# anyway today, 2026-10; standard resolvers and servers need not). TLS: one
# wildcard cert via porkbun DNS-01, so no agent name lands in the CT logs;
# the serve ports' per-agent wildcards are in ./hermes-agents-serve.nix.
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
  certName = "hermes-fyi";
  legacyCert = "hermes-dashboards";
  frontSocket = "/run/nginx/hermes-front.sock";
  # The front door's oauth2-proxy (the header).
  oauth2Socket = "/run/oauth2-proxy.sock";
  # Let's Encrypt only, by DNS-01 only (the header). Without issuewild the
  # issue property governs wildcards as well.
  dns01Only = ''0 issue "letsencrypt.org; validationmethods=dns-01"'';
  scopes = "openid profile email offline_access";

  clientIdOf = user: "hermes-${user}";
  vhostOf = user: "hermes-dashboard-${user}";
  hostOf = user: "${user}.${cfg.agentDomain}";
  # Agents per front-door account.
  agentsOf = lib.foldlAttrs (
    acc: user: u:
    acc // { ${u.account} = (acc.${u.account} or [ ]) ++ [ user ]; }
  ) { } cfg.users;
  # The registrable domain, as ./porkbun-records takes the zone.
  siteOf =
    name:
    let
      labels = lib.splitString "." name;
    in
    lib.concatStringsSep "." (lib.sublist (lib.length labels - 2) 2 labels);
  # nginx vhosts other than the dashboard's own that answer <user>'s name.
  otherVhostsFor =
    user:
    lib.attrNames (
      lib.filterAttrs (
        name: v:
        name != vhostOf user
        && lib.elem (hostOf user) ([ (if v.serverName != null then v.serverName else name) ] ++ v.serverAliases)
      ) config.services.nginx.virtualHosts
    );
  wildcardRecord = {
    A = cfg.publicIPv4;
    AAAA.ipv6OnLink = {
      inherit (config.networking.publicIPv6) interface;
      suffix = config.networking.publicIPv6.token;
    };
  };
  record = wildcardRecord // {
    TXT = "v=spf1 -all";
  };
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
  frontMap =
    variable: f:
    ''
      map $http_x_hermes_account ${variable} {
        default "";
      ${lib.concatStrings (
        lib.mapAttrsToList (
          account: agents:
          let
            value = f agents;
          in
          lib.optionalString (value != null) ''
            "${account}" "${value}";
          ''
        ) agentsOf
      )}}
    '';
  # The phone setup page of one account (the header). Only Nix values go
  # in: agent names are DNS labels (asserted), so nothing needs escaping
  # beyond the URL parameter.
  appPage =
    account: agents:
    let
      entry =
        a:
        let
          url = cfg.users.${a}.publicUrl;
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
      <p>Your assistant's address${lib.optionalString (lib.length agents > 1) "es"}:</p>
      ${lib.concatMapStrings entry agents}
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
      <p>Reading this on a computer? Open https://${cfg.host}/app on your phone instead.</p>
      </body></html>
    '';
  appPages = pkgs.linkFarm "hermes-app-pages" (
    lib.mapAttrsToList (account: agents: {
      name = "${account}.html";
      path = appPage account agents;
    }) agentsOf
  );
in
{
  imports = [
    ./fetch-metadata-gate.nix
    ./porkbun-records
  ];

  options.hyper.hermesDashboard = {
    host = lib.mkOption {
      type = lib.types.str;
      description = "Front door behind oauth2-proxy: https://<host>/ redirects to the signed-in account's dashboard, https://<host>/app lists its addresses for Hermes Mobile. Only our own pages live under its site (the mail owner page).";
    };
    agentDomain = lib.mkOption {
      type = lib.types.str;
      description = "Registrable domain of everything agent-controlled: every agent's dashboard at https://<agent>.<agentDomain>/, its serve ports at https://<port>.<agent>.<agentDomain>/. Must be a site of its own, not <host>'s.";
    };
    legacy = {
      agentDomain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "agents.davhau.com";
        description = "Transition: the dashboards' old parent domain. https://<agent>.<this>/ answers 301 to the dashboard, nothing else. Keeps its wildcard records and certificate.";
      };
      servePorts = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Transition: https://<port>.<host>/, the serve ports' old names, answers 301 to https://<port>.<agent>.<agentDomain>/, nothing else (./hermes-agents-serve.nix).";
      };
    };
    publicIPv4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "38.89.142.76";
      description = "Address of the *.<agentDomain> (and *.<agent>.<agentDomain>) A records; their AAAA is networking.publicIPv6. Null: no DNS records are kept.";
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
        assertion = siteOf cfg.agentDomain == cfg.agentDomain && siteOf cfg.agentDomain != siteOf cfg.host;
        message = "hyper.hermesDashboard.agentDomain: must be a registrable domain of its own (two labels), not ${siteOf cfg.host}, the front door's: agent pages must be a different site.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: u:
        let
          c = config.hyper.oidc.clients.${clientIdOf user} or null;
          others = otherVhostsFor user;
        in
        [
          {
            assertion = config.hyper.hermesAgents ? ${user};
            message = "hyper.hermesDashboard.users.${user}: only an agent of hyper.hermesAgents has a host dashboard unit to publish.";
          }
          {
            assertion = builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" user != null;
            message = "hyper.hermesDashboard.users.${user}: the name is the dashboard's DNS label; use a-z, 0-9 and inner dashes, at most 63.";
          }
          {
            assertion = builtins.match "[0-9]+" user == null && user != "slot";
            message = "hyper.hermesDashboard.users.${user}: all-digit labels are serve ports and `slot` is the agent slot's label; pick another name.";
          }
          {
            # The name's own records are this module's (DNS, the header);
            # another module's A or TXT there would conflict at evaluation,
            # any other type shows up here.
            assertion =
              (
                if cfg.publicIPv4 != null then
                  lib.attrNames config.hyper.porkbunRecords.records.${hostOf user} == lib.attrNames record
                else
                  !(config.hyper.porkbunRecords.records ? ${hostOf user})
              )
              && others == [ ];
            message = "hyper.hermesDashboard.users.${user}: ${hostOf user} is taken by another service (DNS records of its own, or nginx vhosts ${toString others}).";
          }
          {
            assertion =
              c != null
              && !c.public
              && c.secretFile != null
              && c.pkce
              && c.callbackURLs == [ "${u.publicUrl}/auth/callback" ]
              && c.allowedGroups == [ "hermes-${user}" ];
            message = "hyper.hermesDashboard.users.${user}: the inventory must declare the confidential oidc client ${clientIdOf user} for this machine, with pkce, callback ${u.publicUrl}/auth/callback, group hermes-${user} (derived from machines/<machine>/hermes-dashboards.nix).";
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

    # Cross-origin requests (the header): every dashboard, and the front
    # door, whose own flow is navigations only.
    hyper.fetchMetadataGate.virtualHosts = [ cfg.host ] ++ map vhostOf (lib.attrNames cfg.users);

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
      cookie = {
        # Host-only by browser rule: no Domain, Secure, Path=/ (the header).
        name = "__Host-hermes";
        secretFile = config.clan.core.vars.generators.hermes-oauth2-proxy.files.cookie_secret.path;
      };
      redirectURL = "https://${cfg.host}/oauth2/callback";
      email.domains = [ "*" ];
      setXauthrequest = true;
      reverseProxy = true;
      # The socket systemd holds (the header).
      httpAddress = "fd:3";
      # No TCP peer can reach it; peers of the unix socket (nginx) are
      # trusted regardless. Narrow anyway, or oauth2-proxy trusts every
      # address.
      trustedProxyIP = [ "127.0.0.1" ];
      extraConfig = {
        # Accounts may have no email; identify them by username instead.
        oidc-email-claim = "preferred_username";
        insecure-oidc-allow-unverified-email = true;
        code-challenge-method = "S256";
        skip-provider-button = true;
        # Back to the page asked for after the sign-in, on this host only.
        whitelist-domain = cfg.host;
      };
      nginx = {
        domain = cfg.host;
        proxy = "http://unix:${oauth2Socket}:";
        virtualHosts.${cfg.host} = { };
      };
    };

    systemd.sockets.oauth2-proxy = {
      description = "Socket of the hermes front door's oauth2-proxy";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ oauth2Socket ];
      # While the issuer is unreachable the proxy fails at start, and the
      # requests queued on the socket keep activating it; the default
      # trigger limit (20 activations per 2s) would put the socket into
      # the failed state, where it stays after the issuer is back.
      # TriggerLimitIntervalSec=0 disables it (systemd.socket(5)). The
      # restarts still wait RestartSec: the socket starts no service that
      # is waiting to restart (systemd counts that as activating already).
      socketConfig = {
        TriggerLimitIntervalSec = 0;
        SocketUser = "root";
        SocketGroup = config.services.nginx.group;
        SocketMode = "0660";
      };
    };
    # OIDC discovery needs DNS for the issuer, and network-online.target
    # promises nothing where the wait-online services are masked (som). The
    # stock Restart=always at 100ms burnt the start limit within a second of
    # boot and left the front door down; retry every 5s, indefinitely, until
    # the issuer resolves and answers. Requests wait on the socket meanwhile.
    systemd.services.oauth2-proxy = {
      requires = [ "oauth2-proxy.socket" ];
      after = [ "oauth2-proxy.socket" ];
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

    hyper.porkbunRecords.records = lib.mkIf (cfg.publicIPv4 != null) (
      {
        "*.${cfg.agentDomain}" = wildcardRecord;
        ${cfg.agentDomain}.TXT = "v=spf1 -all";
        "_dmarc.${cfg.agentDomain}".TXT = "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s";
        # CAA (the header); its A/AAAA are kept by hand.
        ${cfg.host}.CAA = dns01Only;
      }
      // lib.mapAttrs' (user: _: lib.nameValuePair (hostOf user) record) cfg.users
      // lib.optionalAttrs (cfg.legacy.agentDomain != null) {
        "*.${cfg.legacy.agentDomain}" = wildcardRecord;
        ${cfg.legacy.agentDomain}.CAA = dns01Only;
      }
    );

    security.acme.certs =
      let
        dns01 = domain: {
          inherit domain;
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
      in
      {
        ${certName} = dns01 "*.${cfg.agentDomain}";
        # The front door and its subdomains: the mail owner page
        # (./agent-mail/owner-page.nix) and the serve ports' old names. All
        # DNS-01: CAA allows nothing else under <host> (the header).
        hermes-subdomains = dns01 "*.${cfg.host}" // {
          extraDomainNames = [ cfg.host ];
        };
      }
      // lib.optionalAttrs (cfg.legacy.agentDomain != null) {
        ${legacyCert} = dns01 "*.${cfg.legacy.agentDomain}";
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
        # Every request to an agent's host, a dashboard or a serve port
        # (./hermes-agents-serve.nix), per host and client network (the
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

        ${frontMap "$hermes_front_redirect" (
          agents: if lib.length agents == 1 then "${cfg.users.${lib.head agents}.publicUrl}/" else null
        )}
        ${frontMap "$hermes_front_choices" (
          agents:
          if lib.length agents > 1 then
            "Your hermes dashboards:\\n${lib.concatMapStrings (a: "  ${cfg.users.${a}.publicUrl}/\\n") agents}"
          else
            null
        )}
        # The account's own page file; unknown accounts map to nothing, so
        # the header never reaches a file path.
        map $http_x_hermes_account $hermes_front_app {
          default "";
        ${lib.concatMapStrings (account: ''
          "${account}" "${account}.html";
        '') (lib.attrNames agentsOf)}}
      ''
      + lib.optionalString (cfg.legacy.agentDomain != null) ''
        map $host $hermes_dashboard_legacy {
          default "";
        ${lib.concatStrings (
          lib.mapAttrsToList (user: u: ''
            "${user}.${cfg.legacy.agentDomain}" "${u.publicUrl}";
          '') cfg.users
        )}}
      '';
      virtualHosts = {
        ${cfg.host} = {
          forceSSL = true;
          useACMEHost = "hermes-subdomains";
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
        # Names under agentDomain that are no dashboard (nor a serve port
        # of ./hermes-agents-serve.nix: those are exact names, which nginx
        # matches before this wildcard), and the default server, so a
        # request for an unknown Host on this host never reaches a backend
        # either.
        hermes-dashboard = {
          serverName = "*.${cfg.agentDomain}";
          default = true;
          forceSSL = true;
          useACMEHost = certName;
          locations."/".return = "404";
        };
      }
      // lib.optionalAttrs (cfg.legacy.agentDomain != null) {
        # Transition only: 301 to the new name, never a backend, on 80 and
        # 443 alike; no ACME challenge answer that could follow it (the
        # header).
        hermes-dashboard-legacy = {
          serverName = "*.${cfg.legacy.agentDomain}";
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
        lib.nameValuePair (vhostOf user) {
          serverName = hostOf user;
          forceSSL = true;
          useACMEHost = certName;
          # Server level, so every location inherits them: none adds a
          # header of its own, which would drop these (nginx add_header).
          # The sign-in locations' own limit_req replaces the request
          # limit there (nginx inherits limit_req only into a level without
          # one); the stricter sign-in limit holds.
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
          # The app's sign-in always asks for the passkey (the header).
          locations."= /auth/native/authorize" = signIn // {
            extraConfig = signIn.extraConfig + ''
              proxy_redirect "~^(${lib.escapeRegex config.hyper.oidc.issuer}/authorize\?.*)$" "$1&prompt=login";
            '';
          };
        }
      ) cfg.users;
    };
  };
}
