# Telegram push for Dave's phone over our own ntfy (UnifiedPush), no
# Google and no third-party gateway: https://tg-push.davhau.com/ runs
# Mercurygram's aesgcm-proxy (../../pkgs/aesgcm-proxy), which takes
# Telegram's legacy WebPush, folds its Encryption/Crypto-Key headers into
# the body and forwards it to the phone's UnifiedPush endpoint on
# ntfy.davhau.com (./voice-gateway/edi.nix); Mercurygram on the phone
# decrypts it (end to end: the gateway and ntfy only see ciphertext).
#
# Locked down to that one job:
#   - nginx admits only Telegram's server ranges
#     (https://core.telegram.org/resources/cidr.txt) and only the two
#     routes Mercurygram registers, each naming an ntfy.davhau.com/up*
#     topic as its target: POST /aesgcm?e=<endpoint> (WebPush) and
#     PUT /<endpoint> (Simple Push, secret chats); /fcm is off (no VAPID).
#   - ntfy: anonymous publishing to `up*` topics only (UnifiedPush topics,
#     random 12-char names the distributor picks), Dave reads them. The
#     ACL entries are appended to the ones the voice-ntfy var declares,
#     at service start, so that var (Dave's tokens) is never regenerated.
# Phone side and taps: docs/dave-phone.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  host = "tg-push.davhau.com";
  ntfyHost = config.services.ntfy-sh.settings.base-url;
  listen = "127.0.0.1:2587";
  proxy = pkgs.callPackage ../../pkgs/aesgcm-proxy { };
  telegramRanges = [
    "91.108.56.0/22"
    "91.108.4.0/22"
    "91.108.8.0/22"
    "91.108.16.0/22"
    "91.108.12.0/22"
    "149.154.160.0/20"
    "91.105.192.0/23"
    "91.108.20.0/22"
    "185.76.151.0/24"
    "2001:b28:f23d::/48"
    "2001:b28:f23f::/48"
    "2001:67c:4e8::/48"
    "2001:b28:f23c::/48"
    "2a0a:f280::/32"
  ];
  # The target, URL-encoded the way Mercurygram encodes it
  # (URLEncoder.encode of ntfy's endpoint `https://ntfy.davhau.com/upXXX?up=1`).
  enc = lib.replaceStrings [ "https://" "." ] [ "https%3A%2F%2F" "\\." ] ntfyHost;
  target = "${enc}%2Fup[A-Za-z0-9_-]{1,64}(%3Fup%3D1)?";
  acl = "everyone:up*:wo,dave:up*:rw";
in
{
  assertions = [
    {
      assertion = lib.hasPrefix "https://" ntfyHost && config.services.ntfy-sh.settings.auth-default-access == "deny-all";
      message = "telegram-push-gateway: expects ntfy at an https base-url with auth-default-access deny-all";
    }
  ];

  systemd.services.aesgcm-proxy = {
    description = "Telegram WebPush (aesgcm) to UnifiedPush gateway";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment.LISTEN_ADDR = listen;
    serviceConfig = {
      ExecStart = lib.getExe proxy;
      Restart = "on-failure";
      RestartSec = 5;
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectHostname = true;
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      PrivateUsers = true;
      MemoryDenyWriteExecute = true;
      SystemCallFilter = [
        "@system-service"
        "~@privileged @resources"
      ];
      SystemCallArchitectures = "native";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictRealtime = true;
      RestrictNamespaces = true;
      UMask = "0077";
    };
  };

  services.nginx.appendHttpConfig = ''
    map $request_method:$request_uri $tg_push_ok {
      default 0;
      "~^POST:/aesgcm\?e=${target}$" 1;
      "~^PUT:/${target}$" 1;
    }
  '';
  services.nginx.virtualHosts.${host} = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://${listen}";
      extraConfig = ''
        ${lib.concatMapStrings (r: "allow ${r};\n") telegramRanges}
        deny all;
        if ($tg_push_ok = 0) { return 403; }
        client_max_body_size 8k;
        client_body_buffer_size 8k;
        proxy_read_timeout 30s;
      '';
    };
  };

  # ntfy: append the UnifiedPush ACL to the var's NTFY_AUTH_ACCESS (a
  # comma-separated list; the env var overrides server.yml's auth-access).
  systemd.services.ntfy-sh.serviceConfig.ExecStart = lib.mkForce (
    pkgs.writeShellScript "ntfy-sh-start" ''
      export NTFY_AUTH_ACCESS="''${NTFY_AUTH_ACCESS:+$NTFY_AUTH_ACCESS,}${acl}"
      exec ${config.services.ntfy-sh.package}/bin/ntfy serve -c ${config.environment.etc."ntfy/server.yml".source}
    ''
  );
}
