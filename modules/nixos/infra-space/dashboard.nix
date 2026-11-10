/*
  The infra-space agent's hermes dashboard, published by this host's nginx
  (som only: hyper.infraSpace.dashboard.enable), Dave only.

  Not hyperhermes' dashboards module: it fronts agents that run on its own
  host (nginx dials each agent's root-held loopback port there), and this
  agent runs in the container. So the login is configured in the guest
  (./hermes.nix: hermes' own OIDC gate, the client and group below, the
  client secret as the credential `dashboard-oidc-secret`), and here is only
  the vhost, dialing the guest's veth address, where a socket proxy in the
  guest forwards to core's root-held port. The guest admits nobody but this
  host there, and this host never forwards a new connection into the veth
  (./default.nix), so the vhost is the only way in.

  The vhost does what the dashboards module's does for its agents (see its
  header for the reasons): Host passed through (hermes accepts only its
  public URL's), X-Forwarded-* set by nginx and the client's list replaced,
  only hermes' own cookies forwarded (its cookies.js), framing refused,
  websockets with long timeouts, sign-in rate-limited per IPv4 address or
  IPv6 /64 (its ratelimit.js), the same request limits per client network
  and per host, and the native-app sign-in made to ask the issuer for a
  fresh login (prompt=login). The limits' pool is the guest's socket proxy
  here, not core's bridges: its 256 connections (systemd-socket-proxyd's
  default) stay above the host-wide in-flight cap of 192. The
  deployment's TLS part comes from `virtualHost` (som: hyperhermes'
  exposure, the *.davhau.fyi wildcard certificate).

  This host's nginx (and root) is all that may dial the guest's dashboard
  port: ./default.nix's output gate.

  clan-secret-prompt's page (./secret-prompt: the agent asks Dave for a
  clan var's value there, never in chat) is on the same host, at
  /secret/<id>, from its own guest port. nginx lets a request through only
  with a session the dashboard accepts: an auth subrequest to hermes'
  /api/auth/me with the access-token cookie only (never the refresh token:
  a refresh there would rotate it into a response nobody keeps, and
  pocket-id's reuse detection would end the session), a GET without body.
  Without one it sends the browser to the dashboard's sign-in, back to the
  page afterwards. The page's own limits: the sign-in's request rate, a
  small body; its value is in the POST body only, which nginx logs nowhere
  (the default access log has the request line, the id at most) and keeps
  in memory (client_body_buffer_size = client_max_body_size: no temp
  file). The session's access-token cookie: the __Host- one if present,
  else the bare one (never both, never the first of several).

  The pocket-id client (`clientId`, callback <url>/auth/callback, admitting
  `allowedGroup` only, which Dave's account joins) is declared in the clan
  inventory from ./dashboard-account.nix
  (modules/flake-parts/nixosConfigurations.nix), the hermes-<name>
  convention of som's agent dashboards.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.infraSpace.dashboard;
  account = import ./dashboard-account.nix;
  # the guest's veth address (./default.nix)
  guestAddress = config.containers.infra-space.localAddress;
  inherit (cfg) port;
  vhost = "infra-space-dashboard";
  location = {
    proxyPass = "http://${guestAddress}:${toString port}";
    proxyWebsockets = true;
    recommendedProxySettings = false;
    extraConfig = ''
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $remote_addr;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Prefix "";
      proxy_set_header Forwarded "";
      proxy_set_header Cookie $infra_space_dashboard_cookie;
      proxy_cookie_domain ~.+ $host;
      proxy_read_timeout 1h;
      proxy_send_timeout 1h;
      client_max_body_size 256m;
    '';
  };
  # clan-secret-prompt's page (./secret-prompt), Dave's session checked first
  secretPage = {
    proxyPass = "http://${guestAddress}:${toString cfg.secretPromptPort}";
    recommendedProxySettings = false;
    extraConfig = ''
      auth_request /_infra_space_secret_auth;
      error_page 401 = @infra_space_secret_login;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $remote_addr;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Cookie "";
      proxy_set_header Authorization "";
      proxy_buffering off;
      proxy_read_timeout 35m;
      # The body holds the value: nginx keeps it in memory whole, never
      # in a temp file (a body beyond client_body_buffer_size would be
      # spooled to client_body_temp_path in plaintext). The cap is the
      # buffer, so no accepted body is ever larger than it.
      client_max_body_size 1m;
      client_body_buffer_size 1m;
      client_body_in_file_only off;
      limit_req zone=infra_space_dashboard_login burst=10 nodelay;
      limit_req_status 429;
    '';
  };
  secretAuth = {
    proxyPass = "http://${guestAddress}:${toString port}/api/auth/me";
    recommendedProxySettings = false;
    extraConfig = ''
      internal;
      proxy_method GET;
      proxy_pass_request_body off;
      proxy_set_header Content-Length "";
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $remote_addr;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Prefix "";
      proxy_set_header Forwarded "";
      proxy_set_header Authorization "";
      proxy_set_header Cookie $infra_space_secret_session;
    '';
  };
  signIn = location // {
    extraConfig = location.extraConfig + ''
      limit_req zone=infra_space_dashboard_login burst=10 nodelay;
      limit_req_status 429;
    '';
  };
in
{
  options.hyper.infraSpace.dashboard = {
    enable = lib.mkEnableOption "the infra-space hermes dashboard behind this host's nginx";
    host = lib.mkOption {
      type = lib.types.str;
      example = "infra-space.davhau.fyi";
      description = "The dashboard's host name.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://${cfg.host}";
      defaultText = lib.literalExpression ''"https://''${host}"'';
      description = "The dashboard's origin, as browsers see it.";
    };
    issuer = lib.mkOption {
      type = lib.types.str;
      description = "OIDC issuer (https).";
    };
    authorizationEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.issuer}/authorize";
      defaultText = lib.literalExpression ''"''${issuer}/authorize"'';
      description = "The issuer's authorization endpoint (pocket-id's by default), where the app sign-in gets prompt=login.";
    };
    clientId = lib.mkOption {
      type = lib.types.str;
      default = inputs.hyperhermes.lib.sso.clientIdOf account.name;
      defaultText = lib.literalExpression "hyperhermes.lib.sso.clientIdOf (import ./dashboard-account.nix).name";
      description = "The confidential OIDC client.";
    };
    allowedGroup = lib.mkOption {
      type = lib.types.str;
      default = inputs.hyperhermes.lib.sso.groupOf account.name;
      defaultText = lib.literalExpression "hyperhermes.lib.sso.groupOf (import ./dashboard-account.nix).name";
      description = "The one group whose members get a session.";
    };
    clientSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime path of the client's secret on this host; reaches the guest as a credential.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9119;
      description = "The guest's dashboard port on its veth address.";
    };
    secretPromptPort = lib.mkOption {
      type = lib.types.port;
      default = 9121;
      description = "The guest's clan-secret-prompt port on its veth address.";
    };
    virtualHost = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression "config.services.hyperhermes.exposure.virtualHost config.services.hyperhermes.exposure.certName";
      description = "Listen and TLS settings of the vhost.";
    };
  };

  config = lib.mkIf (config.hyper.infraSpace.enable && cfg.enable) {
    hyper.infraSpace.credentials.dashboard-oidc-secret = cfg.clientSecretFile;
    hyper.infraSpace.guestModules = [
      {
        infraSpace.hermes.dashboard = {
          enable = true;
          inherit (cfg)
            url
            issuer
            clientId
            allowedGroup
            ;
          listenAddress = guestAddress;
          inherit port;
        };
        infraSpace.secretPrompt = {
          enable = true;
          inherit (cfg) url;
          listenAddress = guestAddress;
          port = cfg.secretPromptPort;
        };
      }
    ];

    services.nginx = {
      enable = true;
      additionalModules = [ pkgs.nginxModules.njs ];
      appendHttpConfig = ''
        js_import infra_space_dashboard_cookies from ${inputs.hyperhermes}/modules/dashboards/cookies.js;
        js_set $infra_space_dashboard_cookie infra_space_dashboard_cookies.hermesCookies;
        js_import infra_space_dashboard_ratelimit from ${inputs.hyperhermes}/modules/dashboards/ratelimit.js;
        js_set $infra_space_dashboard_client_net infra_space_dashboard_ratelimit.clientNet;
        limit_req_zone $infra_space_dashboard_client_net zone=infra_space_dashboard_login:1m rate=6r/m;
        limit_req_zone $infra_space_dashboard_client_net zone=infra_space_dashboard_requests:10m rate=50r/s;
        limit_conn_zone $infra_space_dashboard_client_net zone=infra_space_dashboard_conns:10m;
        limit_conn_zone $host zone=infra_space_dashboard_host_conns:1m;
        # the access-token cookie alone (the secret page's auth subrequest):
        # the __Host- one (as hermes sets it on https), else the bare one
        # (plain http, tests). Never a bare one beside a __Host- one: a
        # sibling host may toss a stale bare cookie in front.
        map $http_cookie $infra_space_secret_at_host {
          "~(?:^|;)\s*(?<at>__Host-hermes_session_at=[^;\s]+)" $at;
          default "";
        }
        map $http_cookie $infra_space_secret_at_bare {
          "~(?:^|;)\s*(?<at>hermes_session_at=[^;\s]+)" $at;
          default "";
        }
        map $infra_space_secret_at_host $infra_space_secret_session {
          "" $infra_space_secret_at_bare;
          default $infra_space_secret_at_host;
        }
        map $upstream_http_x_frame_options $infra_space_dashboard_frame_options {
          "" SAMEORIGIN;
          default "";
        }
      '';
      virtualHosts.${vhost} = cfg.virtualHost // {
        serverName = cfg.host;
        # the sign-in locations' own limit_req replaces the request limit
        # there (nginx inherits limit_req only into a level without one)
        extraConfig = ''
          add_header Content-Security-Policy "frame-ancestors 'self'" always;
          add_header X-Frame-Options $infra_space_dashboard_frame_options always;
          limit_req zone=infra_space_dashboard_requests burst=500 nodelay;
          limit_conn infra_space_dashboard_conns 128;
          limit_conn infra_space_dashboard_host_conns 192;
          limit_req_status 429;
          limit_conn_status 429;
        '';
        locations."/" = location;
        locations."= /auth/login" = signIn;
        # (no `{32}`: a brace would end nginx's location line; the service
        # takes exactly 32)
        locations."~ ^/secret/(?<infra_space_secret_id>[0-9a-f]+)$" = secretPage;
        locations."= /_infra_space_secret_auth" = secretAuth;
        locations."@infra_space_secret_login".extraConfig = ''
          return 302 /login?next=/secret/$infra_space_secret_id;
        '';
        locations."= /auth/native/authorize" = signIn // {
          extraConfig = signIn.extraConfig + ''
            proxy_redirect "~^(${lib.escapeRegex cfg.authorizationEndpoint}\?.*)$" "$1&prompt=login";
          '';
        };
      };
    };
  };
}
