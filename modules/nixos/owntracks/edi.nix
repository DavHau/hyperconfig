# edi's part of ./default.nix: the phone's public endpoint and Dave's
# setup page.
#
#   https://<publicHost>/pub  OwnTracks posts here (HTTP mode), basic auth
#       `dave` (htpasswd from owntracks-phone), POST only, 64 KiB, 30/min
#       per client with a burst; nginx dials HA's webhook on cm-pi over
#       yggdrasil with the secret id (an include from the var, so neither
#       the id nor the password is in the store). The phone's Authorization
#       header never reaches HA. Everything else on the host: 404. Its
#       error_log is `crit` only: nginx's upstream errors (cm-pi down) name
#       the upstream URL, i.e. the webhook id, and edi's journal goes to
#       Loki; failed logins stay visible as 401s in the access log.
#   https://bearhouse.davhau.com/api/webhook/<id>  404: bearhouse proxies
#       all of HA, so without this the id would be a second, password-free
#       way into the webhook. owntracks-bearhouse-block writes that
#       location from owntracks-secrets/webhook-id (on edi already) into
#       /run before nginx starts: no further var, no id in the store. It
#       fails open (glob include, `wants`): a broken id file must not take
#       down every vhost on edi for a defence-in-depth rule.
#   https://stats.davhau.com/owntracks/  the setup page and the .otrc file
#       (./phone-config.py), only for a Grafana session (pocket-id, group
#       `stats`: Dave), as the TeamClaude usage pages
#       (../monitoring-teamclaude). No caching, no framing.
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.hyper.owntracks;
  gen = config.clan.core.vars.generators.owntracks-phone;
  secrets = config.clan.core.vars.generators.owntracks-secrets.files;
  bearhouseDir = "/run/owntracks-nginx";
  bearhouseBlock = "${bearhouseDir}/bearhouse-block.conf";
  grafanaPort = config.services.grafana.settings.server.http_port;
  # add_header_inherit merge: keep the server's own add_headers (HSTS, if
  # ever set there) next to these instead of nginx dropping them.
  noStore = ''
    add_header_inherit merge;
    add_header Cache-Control "private, no-store" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
  '';
in
{
  imports = [ ./vars.nix ];

  clan.core.vars.generators.owntracks-phone = {
    dependencies = [ "owntracks-secrets" ];
    files.htpasswd = {
      owner = "nginx";
      restartUnits = [ "nginx.service" ];
    };
    files.proxy-pass = {
      owner = "nginx";
      restartUnits = [ "nginx.service" ];
    };
    files."page.html".owner = "nginx";
    files."config.otrc".owner = "nginx";
    # kept for a manual setup (OwnTracks' own settings screens)
    files.password = { };
    runtimeInputs = [
      pkgs.python3
      pkgs.openssl
    ];
    script = ''
      python3 ${./phone-config.py} "$out" "$in/owntracks-secrets/encryption-key" \
        https://${cfg.publicHost}/pub dave pixel dh
      printf 'proxy_pass http://cm-pi.d:8123/api/webhook/%s;\n' \
        "$(cat "$in/owntracks-secrets/webhook-id")" > "$out"/proxy-pass
    '';
  };

  services.nginx.appendHttpConfig = ''
    limit_req_zone $binary_remote_addr zone=owntracks_pub:1m rate=30r/m;
  '';

  services.nginx.virtualHosts.${cfg.publicHost} = {
    forceSSL = true;
    enableACME = true;
    locations."/".return = "404";
    locations."= /pub" = {
      recommendedProxySettings = false;
      extraConfig = ''
        error_log stderr crit;
        limit_except POST { deny all; }
        auth_basic "owntracks";
        auth_basic_user_file ${gen.files.htpasswd.path};
        limit_req zone=owntracks_pub burst=30 nodelay;
        limit_req_status 429;
        client_max_body_size 64k;
        client_body_buffer_size 64k;
        proxy_set_header Authorization "";
        proxy_set_header Cookie "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
        include ${gen.files.proxy-pass.path};
      '';
    };
  };

  # exact-id prefix match: wins over bearhouse's `location /`
  services.nginx.virtualHosts."bearhouse.davhau.com".extraConfig = ''
    include ${bearhouseDir}/*.conf;
  '';
  systemd.services.owntracks-bearhouse-block = {
    description = "bearhouse's 404 for the OwnTracks webhook id (nginx include)";
    before = [ "nginx.service" ];
    wantedBy = [ "nginx.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Group = "nginx";
      RuntimeDirectory = "owntracks-nginx";
      RuntimeDirectoryMode = "0750";
      RuntimeDirectoryPreserve = "yes";
      UMask = "0227";
    };
    script = ''
      id=$(cat ${secrets.webhook-id.path})
      [[ $id =~ ^[0-9a-f]{64}$ ]] || { echo "webhook-id: not 64 hex chars" >&2; exit 1; }
      printf 'location ^~ /api/webhook/%s { return 404; }\n' "$id" > ${bearhouseBlock}.tmp
      mv ${bearhouseBlock}.tmp ${bearhouseBlock}
    '';
  };
  clan.core.vars.generators.owntracks-secrets.files.webhook-id.restartUnits = [
    "owntracks-bearhouse-block.service"
    "nginx.service"
  ];

  services.nginx.virtualHosts."stats.davhau.com".locations = {
    # Signed in = Grafana knows the session cookie; any other credential
    # is dropped (../monitoring-teamclaude does the same for its pages).
    "= /_owntracks_auth" = {
      proxyPass = "http://127.0.0.1:${toString grafanaPort}/api/user";
      extraConfig = ''
        internal;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Authorization "";
        proxy_set_header X-Grafana-Org-Id "";
      '';
    };
    "@owntracks_login".return = "302 /login?redirectTo=%2Fowntracks%2F";
    "= /owntracks".return = "301 /owntracks/";
    "= /owntracks/" = {
      # Not `alias` on a file: for a URI ending in "/" nginx appends the
      # index name to it (".../page.htmlindex.html is not a directory": 500).
      # try_files with the absolute path serves the file itself.
      root = "/";
      tryFiles = "${gen.files."page.html".path} =404";
      extraConfig = ''
        auth_request /_owntracks_auth;
        error_page 401 = @owntracks_login;
        default_type text/html;
        ${noStore}
        add_header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" always;
      '';
    };
    "= /owntracks/config.otrc" = {
      alias = gen.files."config.otrc".path;
      extraConfig = ''
        auth_request /_owntracks_auth;
        error_page 401 = @owntracks_login;
        default_type application/octet-stream;
        ${noStore}
        add_header Content-Disposition 'attachment; filename="dave-pixel.otrc"' always;
      '';
    };
  };
}
