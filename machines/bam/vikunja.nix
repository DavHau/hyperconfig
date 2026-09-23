# Vikunja behind tasks.davhau.com (edi's reverse proxy). Login also via the
# clan's pocket-id (modules/clan/oidc, client `vikunja`). Both fallbacks on:
# an OIDC login whose preferred_username (or verified email) matches a
# local account links to it instead of creating a second user (openid.go
# fallbackSearchUsers, 2.5.0). Local login stays enabled. The public URL
# is what the SPA calls for /api (and what it derives the OIDC redirect
# from), so it must be the address browsers use, not bam.d: the provider
# list simply never loaded before. The unit runs as a DynamicUser, so the
# root-owned secret rides in through LoadCredential; vikunja expands env
# vars in `.file` paths (config.GetConfigValueFromFile).
{config, ...}:
let
  oidc = config.hyper.oidc.clients.vikunja;
in {
  services.vikunja = {
    enable = true;
    port = 8083;
    frontendScheme = "https";
    frontendHostname = "tasks.davhau.com";
    settings.auth = {
      local.enabled = true;
      openid = {
        enabled = true;
        providers.davhau = {
          name = "DavHau";
          authurl = config.hyper.oidc.issuer;
          clientid = oidc.clientId;
          clientsecret.file = "\${CREDENTIALS_DIRECTORY}/oidc_client_secret";
          scope = "openid profile email";
          usernamefallback = true;
          emailfallback = true;
        };
      };
    };
  };

  systemd.services.vikunja.serviceConfig.LoadCredential = [ "oidc_client_secret:${oidc.secretFile}" ];

  networking.firewall.interfaces.ygg.allowedTCPPorts = [ config.services.vikunja.port ];
}
