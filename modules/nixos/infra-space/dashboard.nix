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
        locations."= /auth/native/authorize" = signIn // {
          extraConfig = signIn.extraConfig + ''
            proxy_redirect "~^(${lib.escapeRegex cfg.authorizationEndpoint}\?.*)$" "$1&prompt=login";
          '';
        };
      };
    };
  };
}
