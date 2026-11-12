# vit's TTS voice picker (./tts.py's HTTP API: GET / page, GET/PUT /voices,
# POST /preview) published at voices.davhau.com by edi's nginx behind the
# clan's pocket-id (modules/clan/oidc, client `voices`, group `voices`:
# Dave only). oauth2-proxy checks the session (auth_request) and the group
# claim again; nginx then dials vit's apiPort over yggdrasil, which vit
# admits from edi's ygg address only (./default.nix).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  host = "voices.davhau.com";
  client = config.hyper.oidc.clients.voices;
  group = lib.head client.allowedGroups;
  vitYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "vit";
    generator = "yggdrasil";
    file = "address";
  };
  apiPort = 10201; # vit's hyper.wyomingLocalSpeech.apiPort
in
{
  clan.core.vars.generators.voices-oauth2-proxy = {
    files.cookie-secret = { };
    runtimeInputs = [ pkgs.openssl pkgs.coreutils ];
    # 32 hex chars = a 32-byte AES key as oauth2-proxy reads it.
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out"/cookie-secret
    '';
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = config.hyper.oidc.issuer;
    clientID = client.clientId;
    clientSecretFile = client.secretFile;
    cookie = {
      name = "__Host-voices";
      secure = true;
      secretFile = config.clan.core.vars.generators.voices-oauth2-proxy.files.cookie-secret.path;
    };
    redirectURL = "https://${host}/oauth2/callback";
    email.domains = [ "*" ];
    scope = "openid email profile groups";
    reverseProxy = true;
    trustedProxyIP = [ "127.0.0.1/32" ];
    httpAddress = "http://127.0.0.1:4180";
    extraConfig = {
      oidc-email-claim = "preferred_username";
      insecure-oidc-allow-unverified-email = true;
      code-challenge-method = "S256";
      skip-provider-button = true;
      allowed-group = group;
      whitelist-domain = host;
    };
    nginx = {
      domain = host;
      virtualHosts.${host} = { };
    };
  };

  services.nginx.virtualHosts.${host} = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://[${vitYgg}]:${toString apiPort}";
      extraConfig = ''
        proxy_set_header Cookie "";
        proxy_read_timeout 120s;
        client_max_body_size 64k;
      '';
    };
  };
}
