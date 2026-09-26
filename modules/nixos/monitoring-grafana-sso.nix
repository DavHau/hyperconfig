# Grafana of the clan-core monitoring server, published at stats.davhau.com
# behind the clan's pocket-id (modules/clan/oidc, client `grafana`).
# pocket-id only lets the client's allowedGroups sign in; Grafana checks the
# `groups` claim again (allowed_groups) and makes every such user a server
# admin. The password login form is disabled; the local admin from the
# grafana-admin vars generator stays as an API-only fallback.
{ config, lib, ... }:
let
  domain = "stats.davhau.com";
  issuer = config.hyper.oidc.issuer;
  client = config.hyper.oidc.clients.grafana;
  group = lib.head client.allowedGroups;
  grafanaPort = config.services.grafana.settings.server.http_port;
in
{
  services.grafana.settings = {
    server = {
      domain = lib.mkForce domain;
      root_url = lib.mkForce "https://${domain}/";
    };
    security = {
      cookie_secure = lib.mkForce true;
      csrf_trusted_origins = lib.mkForce domain;
    };
    auth.disable_login_form = true;
    "auth.generic_oauth" = {
      enabled = true;
      name = "DavHau";
      auto_login = true;
      allow_sign_up = true;
      client_id = client.clientId;
      client_secret = "$__file{/run/credentials/grafana.service/oidc-client-secret}";
      use_pkce = true;
      scopes = "openid profile email groups";
      auth_url = "${issuer}/authorize";
      token_url = "${issuer}/api/oidc/token";
      api_url = "${issuer}/api/oidc/userinfo";
      login_attribute_path = "preferred_username";
      name_attribute_path = "display_name";
      groups_attribute_path = "groups";
      # Not a bare 'GrafanaAdmin': the INI loader unquotes a fully quoted
      # value into a field lookup. Non-members yield false -> strict denies.
      role_attribute_path = "contains(groups[*], '${group}') && 'GrafanaAdmin'";
      allowed_groups = group;
      role_attribute_strict = true;
      allow_assign_grafana_admin = true;
    };
  };

  systemd.services.grafana.serviceConfig.LoadCredential = [
    "oidc-client-secret:${client.secretFile}"
  ];

  services.nginx.virtualHosts.${domain} = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString grafanaPort}";
      proxyWebsockets = true;
    };
  };
}
