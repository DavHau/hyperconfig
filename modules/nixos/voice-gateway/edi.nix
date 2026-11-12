# edi's part of ./default.nix:
#   - ntfy at https://ntfy.davhau.com/ (services.ntfy-sh): auth-default
#     deny-all, users/tokens/ACL declared from the voice-ntfy var
#     (./shared-vars.nix): voicegw may only publish to voice-unlock, dave
#     may only read it. No signup, no web push, no attachments. The
#     Android app (GrapheneOS, no Google services) keeps its own
#     connection ("instant delivery").
#   - https://voice.davhau.com/ -> som's voice-gateway unlock app over
#     yggdrasil (som admits edi's ygg address on that port only). The OIDC
#     login is the gateway's own (pocket-id client `voice`), so nginx only
#     forwards, with a small request rate.
{
  config,
  inputs,
  ...
}:
let
  ntfyHost = "ntfy.davhau.com";
  voiceHost = "voice.davhau.com";
  webPort = 8652; # som's hyper.voiceGateway.webPort
  somYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "som";
    generator = "yggdrasil";
    file = "address";
  };
in
{
  imports = [ ./shared-vars.nix ];

  services.ntfy-sh = {
    enable = true;
    environmentFile = config.clan.core.vars.generators.voice-ntfy.files.env.path;
    # No attachment or web-push settings: attachments need a granted
    # publisher (voicegw only, no files sent), web push is off without keys.
    settings = {
      base-url = "https://${ntfyHost}";
      listen-http = "127.0.0.1:2586";
      behind-proxy = true;
      auth-default-access = "deny-all";
      enable-signup = false;
      enable-login = true;
      enable-reservations = false;
      cache-duration = "12h";
      visitor-request-limit-burst = 30;
    };
  };
  clan.core.vars.generators.voice-ntfy.files.env.restartUnits = [ "ntfy-sh.service" ];

  services.nginx.virtualHosts.${ntfyHost} = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:2586";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3m;
        client_max_body_size 64k;
      '';
    };
  };

  services.nginx.appendHttpConfig = ''
    limit_req_zone $binary_remote_addr zone=voice_unlock:1m rate=20r/m;
  '';
  services.nginx.virtualHosts.${voiceHost} = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://[${somYgg}]:${toString webPort}";
      extraConfig = ''
        limit_req zone=voice_unlock burst=10 nodelay;
        proxy_set_header Authorization "";
        proxy_read_timeout 60s;
        client_max_body_size 4k;
      '';
    };
  };
}
