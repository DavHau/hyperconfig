# The owner page, https://<ownerPage.host>/: where an agent's owner confirms
# allowlist requests. It has its own login, separate from the front door's.
#
# It lives under davhau.com, a site apart from the agent-controlled
# davhau.fyi (hyperhermes' dashboards module), and nginx forwards no login
# cookie to agents (hyperhermes' dashboards module,
# ../hermes-agents-serve.nix), but a page an agent controls must never hold
# the key to this one anyway, nor the front door's session. So this page
# runs an oauth2-proxy of its own:
#   - its session cookie is `__Host-mailgate`: host-only by browser rule
#     (no Domain attribute allowed), Secure, Path=/. No agent-controlled
#     host ever receives it, and no other host can set or overwrite it,
#   - a separate cookie secret, so the front door's session cookie is
#     meaningless here,
#   - prompt=login: every sign-in asks pocket-id for the passkey again,
#     even inside a live pocket-id session, and the session lasts
#     `sessionLifetime` without refresh. Confirming an allowlist entry
#     therefore always follows a fresh passkey check.
# Same OIDC client as the front door (pocket-id's `hermes` client, which
# lists this host's callback; modules/flake-parts/nixosConfigurations.nix).
# Requests a browser sends from another origin are refused unless they are
# top-level GET navigations (hyperhermes' exposure: Fetch Metadata gate);
# the sign-in is
# navigations only, the confirmations are same-origin posts.
#
# nginx passes the signed-in account to mailgate in a header it always
# overwrites; mailgate shows that account's agents only, and checks Origin
# plus a per-account token on every POST.
#
# oauth2-proxy listens on no TCP port but on a unix socket systemd (root)
# holds for the whole uptime (`http-address=fd:3`), root:nginx 0660 in
# /run: no agent talks to it past nginx, and none can take its address
# while it is down or restarting, as it could a loopback port (whoever
# binds first owns it) and then forge X-Auth-Request-* answers. It trusts
# X-Forwarded-* from that socket's peers, which means nginx. The front
# door's and the serve ports' instances listen the same way.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.agentMail;
  host = cfg.ownerPage.host;
  # The front door's client (hyperhermes' lib.sso).
  client = config.hyper.oidc.clients.${inputs.hyperhermes.lib.sso.frontDoorClientId};
  vars = config.clan.core.vars.generators;
  socket = "/run/oauth2-proxy-mailgate.sock";
  address = "unix:${socket}:";
  sessionLifetime = "30m";
  # `--flag=value` (toCommandLineShellGNU's form): oauth2-proxy's boolean
  # flags take no separate argument.
  args = lib.cli.toCommandLineShellGNU { } {
    provider = "oidc";
    oidc-issuer-url = config.hyper.oidc.issuer;
    client-id = client.clientId;
    client-secret-file = "%d/client-secret";
    cookie-secret-file = "%d/cookie-secret";
    cookie-name = "__Host-mailgate";
    cookie-secure = "true";
    cookie-httponly = "true";
    cookie-samesite = "lax";
    cookie-expire = sessionLifetime;
    cookie-refresh = "0";
    # The socket systemd holds (the header).
    http-address = "fd:3";
    redirect-url = "https://${host}/oauth2/callback";
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
    prompt = "login";
  };
in
{
  config = lib.mkIf (cfg.enable && host != null) {
    clan.core.vars.generators.mailgate-oauth2-proxy = {
      files.cookie_secret.restartUnits = [ "oauth2-proxy-mailgate.service" ];
      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssl
      ];
      # oauth2-proxy decodes a cookie secret only as URL-safe base64 and
      # otherwise takes the raw bytes, which must then be 16, 24 or 32
      # long: standard base64 with a '+' or '/' is 44 raw bytes and the
      # proxy refuses to start. 32 hex characters are 32 raw bytes.
      script = ''
        openssl rand -hex 16 | tr -d '\n' > "$out"/cookie_secret
      '';
    };

    systemd.services.oauth2-proxy-mailgate = {
      description = "oauth2-proxy of the agent mail owner page";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = [ "oauth2-proxy-mailgate.socket" ];
      after = [
        "network-online.target"
        "oauth2-proxy-mailgate.socket"
      ];
      # Like the dashboards' instance: OIDC discovery needs the issuer, so
      # retry every 5s, indefinitely, until it answers.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.oauth2-proxy} ${args}";
        DynamicUser = true;
        LoadCredential = [
          "client-secret:${client.secretFile}"
          "cookie-secret:${vars.mailgate-oauth2-proxy.files.cookie_secret.path}"
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
        # No IPAddressDeny: the issuer (pocket-id) is a DNS name whose
        # address is not pinned anywhere in this config, and the resolver
        # must be reachable too.
      };
    };

    systemd.sockets.oauth2-proxy-mailgate = {
      description = "Socket of the agent mail owner page's oauth2-proxy";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ socket ];
      # No trigger limit, as the front door's
      # (hyperhermes' sso module says why).
      socketConfig = {
        TriggerLimitIntervalSec = 0;
        SocketUser = "root";
        SocketGroup = config.services.nginx.group;
        SocketMode = "0660";
      };
    };

    services.hyperhermes.exposure.fetchMetadataGate.virtualHosts = [ host ];
    services.nginx.virtualHosts.${host} = {
      forceSSL = true;
      # *.<front door host> (hyperhermes' sso module)
      useACMEHost = "hermes-subdomains";
      locations."/oauth2/" = {
        proxyPass = "http://${address}";
        recommendedProxySettings = false;
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
        '';
      };
      locations."= /.mailgate-auth".extraConfig = ''
        internal;
        proxy_pass http://${address}/oauth2/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      '';
      locations."@mailgate-login".return = "307 https://${host}/oauth2/start?rd=$scheme://$host$request_uri";
      locations."/" = {
        proxyPass = "http://unix:/run/mailgate/owner.sock:";
        recommendedProxySettings = false;
        extraConfig = ''
          auth_request /.mailgate-auth;
          auth_request_set $mailgate_account $upstream_http_x_auth_request_preferred_username;
          error_page 401 = @mailgate-login;
          proxy_set_header Host $host;
          proxy_set_header X-Mailgate-Account $mailgate_account;
          proxy_set_header Cookie "";
          client_max_body_size 64k;
        '';
      };
    };
  };
}
