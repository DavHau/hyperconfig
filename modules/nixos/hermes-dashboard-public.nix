# Public web dashboards for native hermes agents, one shared vhost:
# https://<host>/ (AAAA -> this host's stable public v6,
# networking.publicIPv6Token) -> nginx -> oauth2-proxy (auth_request against
# the clan's pocket-id, modules/clan/oidc) -> the dashboard backend that
# belongs to the signed-in account, on 127.0.0.1:20000+uid.
#
# Everyone uses the same URL; the account decides which hermes answers.
# nginx maps the authenticated preferred_username (oauth2-proxy's
# X-Auth-Request-Preferred-Username, --set-xauthrequest) to a backend port
# and 403s any other account. Authorisation is therefore twofold:
# pocket-id only issues tokens for the `hermes` client to members of the
# `hermes` group, and only accounts named in users.<user>.account reach a
# backend at all.
#
# The backends stay exactly as spaces' native.nix runs them: loopback bind,
# which hermes treats as "trusted operator" (no login gate, a static
# session token injected into the SPA). That is safe here because nothing
# reaches the port without oauth2-proxy's cookie, and spaces' owner-only
# iptables rule (hermes/firewall.nix) still rejects every other local uid;
# nginx gets its own RETURN rule ahead of it. No path prefix, so none of
# the upstream X-Forwarded-Prefix gaps apply. The root-held forward at
# users.<user>.dashboardPort and hermes-desktop keep working unchanged.
#
# Secrets (clan vars, root-owned, LoadCredential): the `hermes` client
# secret is the shared oidc var the oidc service declares; the cookie
# secret is per-machine (`hermes-oauth2-proxy`).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.hermesDashboard;
  portOf = user: 20000 + config.users.users.${user}.uid;
  client = config.hyper.oidc.clients.${cfg.oidcClient};
  # Nothing listens here on purpose: nginx answers 403 for accounts
  # without a dashboard from its own server block on this port.
  forbiddenPort = 20000 - 1;
in
{
  options.hyper.hermesDashboard = {
    host = lib.mkOption {
      type = lib.types.str;
      description = "Shared public hostname; every user's dashboard lives at https://<host>/.";
    };
    oidcClient = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = "Id of this machine's oidc client (inventory, roles.client.machines.<host>.settings.clients).";
    };
    users = lib.mkOption {
      default = { };
      description = "Native hermes users whose dashboard is published.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              account = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "pocket-id username that lands on this dashboard.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.users != { }) {
    assertions =
      lib.mapAttrsToList (user: _: {
        assertion = config.services.hermes-microvm.users.${user}.native or false;
        message = "hyper.hermesDashboard.users.${user}: only a native hermes user has a host dashboard unit to publish.";
      }) cfg.users
      ++ [
        {
          assertion = config.hyper.oidc.clients ? ${cfg.oidcClient};
          message = "hyper.hermesDashboard: the inventory declares no oidc client `${cfg.oidcClient}` for this machine.";
        }
        {
          assertion =
            lib.length (lib.unique (lib.mapAttrsToList (_: u: u.account) cfg.users))
            == lib.length (lib.attrNames cfg.users);
          message = "hyper.hermesDashboard: two dashboards claim the same account.";
        }
      ];

    clan.core.vars.generators.hermes-oauth2-proxy = {
      files.cookie_secret = { };
      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssl
      ];
      script = ''
        openssl rand -base64 32 | tr -d '\n' > "$out"/cookie_secret
      '';
    };

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

    # nginx may dial the owner-gated backend ports. -I puts them before
    # the REJECT spaces appends for each port.
    systemd.services.hermes-firewall.script = lib.mkAfter (
      lib.concatMapStrings (user: ''
        iptables -w -I hermes-microvm 1 -p tcp --dport ${toString (portOf user)} -m owner --uid-owner nginx -j RETURN
      '') (lib.attrNames cfg.users)
    );

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
      appendHttpConfig = ''
        map $hermes_account $hermes_backend {
          default 127.0.0.1:${toString forbiddenPort};
        ${lib.concatStrings (
          lib.mapAttrsToList (user: u: ''
            "${u.account}" 127.0.0.1:${toString (portOf user)};
          '') cfg.users
        )}
        }
      '';
      virtualHosts = {
        ${cfg.host} = {
          forceSSL = true;
          enableACME = true;
          locations."/" = {
            proxyPass = "http://$hermes_backend";
            # /api/ws and /api/pty are long-lived websockets; the PTY
            # stream and SSE status feeds sit idle far longer than 60s.
            proxyWebsockets = true;
            # hermes accepts only a loopback Host (and WS Origin) on a
            # loopback bind (web_server.py _is_accepted_host,
            # web_server_chat.py _ws_host_origin_reason); declaring the
            # public host instead would re-arm its own auth gate. So the
            # recommended header set (Host $host) is replaced by hand.
            recommendedProxySettings = false;
            extraConfig = ''
              auth_request_set $hermes_account $upstream_http_x_auth_request_preferred_username;
              proxy_set_header Host 127.0.0.1;
              proxy_set_header Origin "";
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_read_timeout 1h;
              proxy_send_timeout 1h;
              client_max_body_size 256m;
            '';
          };
        };
        hermes-forbidden = {
          serverName = "_";
          listen = [
            {
              addr = "127.0.0.1";
              port = forbiddenPort;
            }
          ];
          locations."/".return = "403 'No hermes dashboard for this account.\\n'";
          extraConfig = "default_type text/plain;";
        };
      };
    };
  };
}
