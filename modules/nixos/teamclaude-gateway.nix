# TeamClaude: pooled Claude subscription gateway at
# https://teamclaude.davhau.com/, a copy of project-zero's pubproxy01 setup
# (../geninf/project-zero: modules/nixos/teamclaude-gateway.nix,
# docs/teamclaude-gateway.md), with its own key and its own accounts.
#
# TeamClaude stays on loopback. nginx owns public TLS and is the gate the
# public sees: it checks the gateway key in either header clients use (omp
# sends `Authorization: Bearer <key>`, Claude Code x-api-key or a bearer).
# TeamClaude (>= 1.1.20) also checks the key itself on every request that
# carries a forwarding header, so nginx presents the same key to it as
# x-api-key on each request it lets through, and proxy.trustLoopback is off
# so a loopback caller cannot skip the second gate. Two gates, one key.
#
# Add an account (as root on som; open the printed URL, sign in with the
# Claude account being contributed, paste the callback back):
#   sudo -u teamclaude -H env TEAMCLAUDE_CONFIG=/var/lib/teamclaude/teamclaude.json teamclaude login
# The key clients present:
#   clan vars get som teamclaude-gateway-key/key
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  domain = "teamclaude.davhau.com";
  apiKeyFile = config.clan.core.vars.generators.teamclaude-gateway-key.files.key.path;
  configFile = config.clan.core.vars.generators.teamclaude-config.files."config.json".path;
  # Everything but the proxy key, which is the only secret in the config. A
  # change here reaches the service on its next restart via preStart.
  settingsFile = pkgs.writeText "teamclaude-settings.json" (
    builtins.toJSON {
      proxy = {
        host = "127.0.0.1";
        port = 3456;
        trustLoopback = false;
      };
      upstream = "https://api.anthropic.com";
      # Owners keep the last 40% of their quota (project-zero decision 0126).
      switchThreshold = 0.6;
      warmupSeconds = 0;
      distributeSessions = true;
    }
  );
  tokenMapDir = "/run/nginx-teamclaude-auth";
in
{
  imports = [ inputs.teamclaude.nixosModules.default ];

  clan.core.vars.generators = {
    # Shared, so a fleet machine can present it as a client without a second
    # copy of the secret drifting on rotation. The `sk-ant-oat01-` prefix is
    # load-bearing: Anthropic accepts subscription OAuth only on requests
    # that present as Claude Code, and omp/Pi emulate Claude Code only when
    # their key looks like a subscription token. A plain hex key turns every
    # omp request into a 429.
    teamclaude-gateway-key = {
      share = true;
      files.key.secret = true;
      runtimeInputs = [ pkgs.openssl ];
      script = ''
        printf 'sk-ant-oat01-%s\n' "$(openssl rand -hex 32)" > "$out/key"
      '';
    };
    teamclaude-config = {
      dependencies = [ "teamclaude-gateway-key" ];
      files."config.json".secret = true;
      runtimeInputs = [ pkgs.jq ];
      script = ''
        api_key=$(cat "$in/teamclaude-gateway-key/key")
        jq -n --arg apiKey "$api_key" '{ proxy: { apiKey: $apiKey } }' > "$out/config.json"
      '';
    };
  };

  services.teamclaude = {
    enable = true;
    configSource = "/run/credentials/teamclaude.service/config.json";
    host = "127.0.0.1";
    openFirewall = false;
    serviceConfig = {
      LoadCredential = "config.json:${configFile}";
      AmbientCapabilities = "";
      CapabilityBoundingSet = "";
      LockPersonality = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };

  # The upstream module copies config.json into the state directory only
  # when nothing is there yet, because that file also holds the enrolled
  # accounts and their refreshed OAuth tokens; no later change to the
  # generated config (a rotated key) would ever reach the service. So merge
  # on every start: the Nix settings, then the secret, win over the live
  # file, except `accounts`, which is runtime state and stays as the service
  # left it. Runs as root (PermissionsStartOnly), after the module's own
  # copy-if-missing.
  systemd.services.teamclaude.preStart = lib.mkAfter ''
    live=/var/lib/teamclaude/teamclaude.json
    src=${lib.escapeShellArg config.services.teamclaude.configSource}
    if [ -e "$live" ]; then
      ${pkgs.jq}/bin/jq -s '.[0] * .[1] * (.[2] | del(.accounts)) | .accounts //= []' \
        "$live" ${settingsFile} "$src" > "$live.merged"
      ${pkgs.coreutils}/bin/install -m 0600 -o teamclaude -g teamclaude "$live.merged" "$live"
      ${pkgs.coreutils}/bin/rm -f "$live.merged"
    fi
  '';

  services.nginx = {
    # `Bearer sk-ant-oat01-<64 hex>` is 84 characters; with nginx's hash
    # metadata it does not fit the default 64-byte bucket.
    mapHashBucketSize = 128;
    # Two maps and a third over their concatenation, because nginx `if`
    # cannot AND two variables: each header map yields 1 for "no match", so
    # only "11" -- neither header carried the key -- is a rejection.
    appendHttpConfig = ''
      map $http_x_api_key $teamclaude_bad_api_key {
        default 1;
        include ${tokenMapDir}/api-key.conf;
      }

      map $http_authorization $teamclaude_bad_bearer {
        default 1;
        include ${tokenMapDir}/bearer.conf;
      }

      map "$teamclaude_bad_api_key$teamclaude_bad_bearer" $teamclaude_bad_key {
        default 0;
        "11" 1;
      }
    '';

    virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = domain;
      # TeamClaude's status and steering API stays off the shared data-plane
      # credential: administrators use it on loopback, presenting the key as
      # x-api-key; the public gets no control-plane access.
      locations."^~ /teamclaude/".extraConfig = ''
        if ($teamclaude_bad_key) {
          return 401;
        }
        return 404;
      '';
      locations."/" = {
        proxyPass = "http://127.0.0.1:3456";
        proxyWebsockets = true;
        # key.conf is `set $teamclaude_key "<key>";`, written by the auth
        # oneshot next to the maps; `set` is location-scope, so it is
        # included here. TeamClaude reads the proxy key from x-api-key only.
        extraConfig = ''
          if ($teamclaude_bad_key) {
            return 401;
          }
          include ${tokenMapDir}/key.conf;
          proxy_set_header x-api-key $teamclaude_key;
          proxy_buffering off;
          proxy_request_buffering off;
          proxy_cache off;
          gzip off;
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
        '';
      };
    };
  };

  systemd.services.nginx-teamclaude-auth = {
    description = "API-key map for the TeamClaude gateway";
    requiredBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "nginx";
      Group = "nginx";
      RuntimeDirectory = "nginx-teamclaude-auth";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
      LoadCredential = [ "api-key:${apiKeyFile}" ];
    };
    script = ''
      umask 077
      key=$(cat "$CREDENTIALS_DIRECTORY/api-key")
      [ -n "$key" ] || { echo "gateway key is empty; not writing a map" >&2; exit 1; }
      printf '"%s" 0;\n' "$key" > "$RUNTIME_DIRECTORY/api-key.conf"
      printf '"Bearer %s" 0;\n' "$key" > "$RUNTIME_DIRECTORY/bearer.conf"
      # nginx's `$var` is literal here; spelled as a %s so shellcheck (SC2016)
      # does not read it as an unexpanded shell variable.
      printf 'set $%s "%s";\n' teamclaude_key "$key" > "$RUNTIME_DIRECTORY/key.conf"
    '';
  };

  # DNS-01 like som's other certificates: som's IPv4 arrives forwarded from
  # sgp, and the porkbun key is root's anyway.
  security.acme.certs.${domain} = {
    inherit domain;
    dnsProvider = "porkbun";
    group = "nginx";
    credentialFiles = {
      PORKBUN_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.apikey.path;
      PORKBUN_SECRET_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.secretkey.path;
    };
    # som's upstream answers REFUSED for names that do not exist yet, which
    # ends lego's SOA walk (./agent-mail/default.nix).
    dnsResolver = "1.1.1.1:53";
  };

  # A: sgp's IPv4, forwarded here like the hermes dashboards'; AAAA: som's
  # own public address.
  hyper.porkbunRecords.records.${domain} = {
    A = config.hyper.hermesDashboard.publicIPv4;
    AAAA.ipv6OnLink = {
      inherit (config.networking.publicIPv6) interface;
      suffix = config.networking.publicIPv6.token;
    };
  };
}
