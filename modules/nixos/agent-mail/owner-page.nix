# The owner page, https://<ownerPage.host>/: where an agent's owner confirms
# allowlist requests. It has its own login, separate from the dashboards'.
#
# The dashboards' oauth2-proxy session cookie is scoped to the dashboard
# host and every subdomain of it (the serve ports need it), and every one of
# those hosts proxies to something an agent controls. nginx no longer
# forwards login cookies to agents (../hermes-dashboard-public.nix,
# ../hermes-agents-serve.nix), but a page an agent controls must never hold
# the key to this one anyway. So this page runs a second oauth2-proxy:
#   - its session cookie is `__Host-mailgate`: host-only by browser rule
#     (no Domain attribute allowed), Secure, Path=/. No agent-controlled
#     host ever receives it, and no other host can set or overwrite it,
#   - a separate cookie secret, so the dashboards' session cookie is
#     meaningless here,
#   - prompt=login: every sign-in asks pocket-id for the passkey again,
#     even inside a live pocket-id session, and the session lasts
#     `sessionLifetime` without refresh. Confirming an allowlist entry
#     therefore always follows a fresh passkey check.
# Same OIDC client as the dashboards (pocket-id's `hermes` client, which
# lists this host's callback; modules/flake-parts/nixosConfigurations.nix).
#
# nginx passes the signed-in account to mailgate in a header it always
# overwrites; mailgate shows that account's agents only, and checks Origin
# plus a per-account token on every POST.
#
# oauth2-proxy's loopback port answers nginx and root only (an owner gate in
# mailgate-firewall, ./mail.nix), and it trusts X-Forwarded-* from loopback
# only, which after that gate means nginx. The dashboards' instance gets the
# same gate in ../hermes-dashboard-oauth2-gate.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.agentMail;
  host = cfg.ownerPage.host;
  dashboard = config.hyper.hermesDashboard;
  client = config.hyper.oidc.clients.${dashboard.oidcClient};
  vars = config.clan.core.vars.generators;
  port = 4181;
  address = "127.0.0.1:${toString port}";
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
    http-address = address;
    redirect-url = "https://${host}/oauth2/callback";
    upstream = "static://202";
    email-domain = "*";
    set-xauthrequest = "true";
    reverse-proxy = "true";
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
      script = ''
        openssl rand -base64 32 | tr -d '\n' > "$out"/cookie_secret
      '';
    };

    systemd.services.oauth2-proxy-mailgate = {
      description = "oauth2-proxy of the agent mail owner page";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      # The owner gate on its port comes first.
      requires = [ "mailgate-firewall.service" ];
      after = [
        "network-online.target"
        "mailgate-firewall.service"
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

    # The owner gate: only nginx and root dial the port. Rides
    # mailgate-firewall, whose mailgate-lo chain sees every new loopback
    # connection (IPv4 and IPv6) and is rebuilt whole on every start.
    systemd.services.mailgate-firewall.script = lib.mkAfter ''
      for ipt in iptables ip6tables; do
        for u in ${config.services.nginx.user} 0; do
          $ipt -w -A mailgate-lo -p tcp --dport ${toString port} -m owner --uid-owner "$u" -j RETURN
        done
        $ipt -w -A mailgate-lo -p tcp --dport ${toString port} -j REJECT --reject-with tcp-reset
      done
    '';

    services.nginx.virtualHosts.${host} = {
      forceSSL = true;
      useACMEHost = "hermes-serve";
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
