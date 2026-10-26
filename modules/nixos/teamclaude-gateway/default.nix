# TeamClaude: pooled Claude subscription gateway at
# https://teamclaude.davhau.com/, after project-zero's pubproxy01 setup
# (../geninf/project-zero: modules/nixos/teamclaude-gateway.nix,
# docs/teamclaude-gateway.md), with its own keys and its own accounts.
#
# TeamClaude stays on loopback behind nginx, which owns public TLS. The key
# check is TeamClaude's own: it authenticates every request against the
# operator key (proxy.apiKey, the clan var below) and every runtime client
# key (proxy.clientKeys), and proxy.trustLoopback is off so a loopback
# caller -- nginx included -- is never exempt. It reads the key from
# x-api-key only, while omp sends `Authorization: Bearer <key>` and Claude
# Code either, so nginx hands a bearer over as x-api-key when the request
# carries none. Unlike project-zero, nginx holds no key of its own: a key
# minted at runtime works without a deploy.
#
# Some client keys are static, declared in hyper.teamclaudeGateway.clientKeys
# (client name -> clan generator whose `key` file holds the key): our own
# infrastructure's, the shared clan var teamclaude-api-key
# (../teamclaude-api-key.nix) as `hyperconfig`, and one per hermes agent
# that routes its Anthropic provider here (hyperhermes' teamclaude, wired
# in ../../../machines/som/hermes-agents.nix). The
# config var carries them and preStart keeps them in proxy.clientKeys on
# every start. `teamclaude-keys revoke <name>` therefore lasts only until
# the next restart; drop the declaration or rotate the var instead.
#
# Every other client key, one per person or machine, is minted and revoked
# at runtime (as root on som; usage is booked per name in `teamclaude status`):
#   teamclaude-keys add <name>      prints the new key once
#   teamclaude-keys list | show <name> | revoke <name>
# Add an account (as root on som; open the printed URL, sign in with the
# Claude account being contributed, paste the callback back):
#   sudo -u teamclaude -H env TEAMCLAUDE_CONFIG=/var/lib/teamclaude/teamclaude.json teamclaude login
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.teamclaudeGateway;
  domain = "teamclaude.davhau.com";
  stateFile = "/var/lib/teamclaude/teamclaude.json";
  configFile = config.clan.core.vars.generators.teamclaude-config.files."config.json".path;
  # Ordered once, so the jq arguments and the array line up.
  staticClients = lib.mapAttrsToList (name: generator: { inherit name generator; }) cfg.clientKeys;
  # Each enrolled account serves up to 98% of every quota bucket (5h, 7d,
  # per-model 7d), as a ratio, like TeamClaude itself spells it. Two settings
  # carry it (docs/quota.md):
  #   - switchThreshold, fleet-wide: rotation prefers another account at this
  #     level, but it is only a preference; when every account is over it the
  #     proxy still sends a revalidating request.
  #   - accounts[].maxUsage, per account: the hard cap. At it (`>=`) the
  #     account gets nothing, the revalidation probe included, so no account
  #     ever goes past 98% (barring a request already in flight).
  # maxUsage lives on each account entry, which is runtime state, so preStart
  # stamps it onto every account; one enrolled by `teamclaude login` gets it
  # on the next service restart (switchThreshold covers it until then).
  usageCap = 0.98;
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
      switchThreshold = usageCap;
      warmupSeconds = 0;
      distributeSessions = true;
    }
  );
  teamclaudeKeys = pkgs.writeShellScriptBin "teamclaude-keys" ''
    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      echo "teamclaude-keys: run as root" >&2
      exit 1
    fi
    exec ${pkgs.util-linux}/bin/runuser -u teamclaude -- \
      ${pkgs.coreutils}/bin/env TEAMCLAUDE_CONFIG=${stateFile} \
      ${pkgs.nodejs}/bin/node ${./keys.mjs} \
      ${config.services.teamclaude.package}/share/teamclaude/src "$@"
  '';
in
{
  imports = [
    inputs.teamclaude.nixosModules.default
    ../teamclaude-api-key.nix
  ];

  options.hyper.teamclaudeGateway.clientKeys = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      dave-hermes = "teamclaude-hermes-dave-hermes";
    };
    description = ''
      Static client keys: client name (as `teamclaude status` books usage)
      -> clan vars generator on this machine (or shared) whose `key` file
      holds the key. Each is kept in proxy.clientKeys on every start.
    '';
  };

  config = {
    hyper.teamclaudeGateway.clientKeys.hyperconfig = "teamclaude-api-key";

    clan.core.vars.generators = {
      # The operator key (proxy.apiKey): the control plane on loopback and
      # teamclaude-keys' reload call. Clients get their own runtime keys.
      # Shared, so a fleet machine can still present it as a client. The
      # `sk-ant-oat01-` prefix is load-bearing: Anthropic accepts subscription
      # OAuth only on requests that present as Claude Code, and omp/Pi
      # emulate Claude Code only when their key looks like a subscription
      # token. A plain hex key turns every omp request into a 429.
      teamclaude-gateway-key = {
        share = true;
        files.key.secret = true;
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          printf 'sk-ant-oat01-%s\n' "$(openssl rand -hex 32)" > "$out/key"
        '';
      };
      teamclaude-config = {
        dependencies = [ "teamclaude-gateway-key" ] ++ map (c: c.generator) staticClients;
        files."config.json" = {
          secret = true;
          restartUnits = [ "teamclaude.service" ];
        };
        runtimeInputs = [ pkgs.jq ];
        script = ''
          jq -n \
            --rawfile apiKey "$in/teamclaude-gateway-key/key" \
            ${
              lib.concatImapStringsSep " \\\n  " (
                i: c:
                "--arg n${toString i} ${lib.escapeShellArg c.name} --rawfile k${toString i} \"$in/${c.generator}/key\""
              ) staticClients
            } \
            '{ proxy: {
                apiKey: ($apiKey | rtrimstr("\n")),
                clientKeys: [ ${
                  lib.concatImapStringsSep ", " (
                    i: _: "{ name: $n${toString i}, key: ($k${toString i} | rtrimstr(\"\\n\")) }"
                  ) staticClients
                } ]
              } }' > "$out/config.json"
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
    # file, except two runtime lists. `accounts` stays as the service left it
    # but for its maxUsage, which is set to usageCap. `proxy.clientKeys` keeps
    # every runtime-minted entry and gets the secret's static entries on top,
    # replacing a live entry of the same name (a rotated static key). Runs as
    # root (PermissionsStartOnly), after the module's own copy-if-missing.
    #
    # Every start, and with no account enrolled the service restarts every
    # 5 s, so the merge must not disturb a concurrent writer (teamclaude-keys,
    # a `teamclaude login`): it takes TeamClaude's own advisory lock
    # (src/config.js: <config>.lock, O_EXCL, {"pid","at"}, give up after 2 s)
    # and replaces the file by rename of a copy that is already
    # teamclaude-owned 0600, so no reader ever sees a root-owned file.
    systemd.services.teamclaude.preStart = lib.mkAfter ''
      live=${stateFile}
      src=${lib.escapeShellArg config.services.teamclaude.configSource}
      if [ -e "$live" ]; then
        lock="$live.lock"
        held=
        for _ in $(seq 80); do
          if (set -C; printf '{"pid":%d,"at":%d}' "$$" "$(date +%s%3N)" > "$lock") 2>/dev/null; then
            chown teamclaude:teamclaude "$lock"
            held=1
            break
          fi
          sleep 0.025
        done
        tmp=$(mktemp "$live.merged.XXXXXX")
        ${pkgs.jq}/bin/jq -s --argjson cap ${builtins.toJSON usageCap} '
          .[0] as $live
          | (.[2].proxy.clientKeys // []) as $static
          | $live * .[1] * (.[2] | del(.accounts) | del(.proxy.clientKeys))
          | .accounts = ((.accounts // []) | map(.maxUsage = $cap))
          | .proxy.clientKeys = (
              [ ($live.proxy.clientKeys // [])[] | select(.name as $n | $static | all(.name != $n)) ]
              + $static)
        ' "$live" ${settingsFile} "$src" > "$tmp"
        chown teamclaude:teamclaude "$tmp"
        chmod 0600 "$tmp"
        mv -f "$tmp" "$live"
        [ -z "$held" ] || rm -f "$lock"
      fi
    '';

    environment.systemPackages = [ teamclaudeKeys ];

    services.nginx = {
      # The key a request presents: x-api-key, else the bearer.
      appendHttpConfig = ''
        map $http_authorization $teamclaude_bearer {
          default "";
          "~^Bearer\s+(?<key>\S+)$" $key;
        }

        map $http_x_api_key $teamclaude_key {
          "" $teamclaude_bearer;
          default $http_x_api_key;
        }
      '';

      virtualHosts.${domain} = {
        forceSSL = true;
        useACMEHost = domain;
        # TeamClaude's status and steering API stays off the public name:
        # the operator uses it on loopback with the operator key.
        locations."^~ /teamclaude/".return = "404";
        locations."/" = {
          proxyPass = "http://127.0.0.1:3456";
          proxyWebsockets = true;
          extraConfig = ''
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
      A = config.services.hyperhermes.exposure.publicIPv4;
      AAAA.ipv6OnLink = {
        inherit (config.networking.publicIPv6) interface;
        suffix = config.networking.publicIPv6.token;
      };
    };
  };
}
