# Dave's builds of the two Hermes phone apps (../pkgs/android-apps),
# signed with our own key and served for Obtainium at
# https://<host>/apps/ (services.hyperhermes.androidApps).
#
# Signing: the clan vars generator android-app-signing (shared, prompt-free,
# secret; nixosModules.clan fills keystoreFile/passwordFile from it) holds
# one PKCS#12 keystore with key `hermes`. The key never enters the store:
# android-apps-sign.service signs the store's unsigned, aligned APKs with
# apksigner (v1-v3) into /var/lib/android-apps whenever the APKs or the key
# change, and nginx serves that directory. Losing the key means every
# phone must uninstall (data lost) to take the next build: back it up
# (`clan vars get <machine> android-app-signing/keystore.p12`).
#
# Serving: plain HTTPS, no sign-in. The APKs hold no secret (the apps ask
# for the server address and log in on the phone), Obtainium cannot pass
# an SSO login, and the same apps are public on GitHub. The index page
# lists every APK; Obtainium's "HTML" source on https://<host>/apps/
# picks the newest link (the README says how).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.androidApps;
  dir = "/var/lib/android-apps";
  apps = lib.attrValues cfg.apps;
  index = pkgs.writeText "android-apps-index.html" ''
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>Hermes apps</title></head><body>
    <h1>Hermes apps (Dave's builds)</h1>
    <ul>
    ${lib.concatMapStrings (a: ''
      <li><a href="${a.pname}-${a.version}.apk">${a.pname}-${a.version}.apk</a></li>
    '') apps}
    </ul></body></html>
  '';
  sign = pkgs.writeShellScript "android-apps-sign" ''
    set -euo pipefail
    umask 022
    ANDROID_KS_PASS=$(cat "$CREDENTIALS_DIRECTORY/password")
    export ANDROID_KS_PASS
    tmp=$(mktemp -d ${dir}/.sign.XXXXXX)
    trap 'rm -rf "$tmp"' EXIT
    ${lib.concatMapStrings (a: ''
      ${pkgs.apksigner}/bin/apksigner sign --min-sdk-version ${toString cfg.minSdk} \
        --ks "$CREDENTIALS_DIRECTORY/keystore" --ks-type PKCS12 --ks-key-alias hermes \
        --ks-pass env:ANDROID_KS_PASS --key-pass env:ANDROID_KS_PASS \
        --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
        --out "$tmp/${a.pname}-${a.version}.apk" ${a}/${a.apk}
      ${pkgs.apksigner}/bin/apksigner verify --min-sdk-version ${toString cfg.minSdk} "$tmp/${a.pname}-${a.version}.apk"
    '') apps}
    cp ${index} "$tmp/index.html"
    chmod 0644 "$tmp"/*
    # Replace the served set at once; old versions go.
    find ${dir} -maxdepth 1 -type f -delete
    mv "$tmp"/* ${dir}/
  '';
in
{
  options.services.hyperhermes.androidApps = {
    enable = lib.mkEnableOption "Dave's signed builds of the Hermes phone apps at https://<host>/apps/";
    host = lib.mkOption {
      type = lib.types.str;
      example = "hermes.example.com";
      description = "nginx virtual host (an existing one) that serves /apps/.";
    };
    apps = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      description = "Unsigned APK packages (passthru.apk names the file).";
    };
    minSdk = lib.mkOption {
      type = lib.types.ints.positive;
      default = 26;
      description = "Lowest Android API level the signatures must cover (both apps' minSdk).";
    };
    keystoreFile = lib.mkOption {
      type = lib.types.str;
      description = "PKCS#12 keystore with key `hermes` (runtime path, never the store).";
    };
    passwordFile = lib.mkOption {
      type = lib.types.str;
      description = "The keystore's and key's password (runtime path).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];

    systemd.services.android-apps-sign = {
      description = "Sign the Hermes phone app builds for /apps/";
      wantedBy = [ "multi-user.target" ];
      # Re-signs on every switch that changes an APK (the script's store path).
      restartTriggers = [ sign ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = [
          "keystore:${cfg.keystoreFile}"
          "password:${cfg.passwordFile}"
        ];
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ dir ];
        NoNewPrivileges = true;
        ExecStart = sign;
      };
    };

    services.nginx.virtualHosts.${cfg.host}.locations = {
      # Public (the header): ahead of the host's sign-in.
      "^~ /apps/" = {
        alias = "${dir}/";
        extraConfig = ''
          auth_request off;
          types { application/vnd.android.package-archive apk; text/html html; }
          default_type application/octet-stream;
          add_header X-Content-Type-Options nosniff always;
          add_header Cache-Control "no-cache" always;
        '';
      };
    };
  };
}
