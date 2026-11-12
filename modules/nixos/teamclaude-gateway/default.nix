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
# Of TeamClaude's own API only GET /teamclaude/status is public, gated by
# the same check (any client key reads it): per-account quota for the
# anthropic-usage bar widget on amy (../noctalia-anthropic-usage). The rest
# of /teamclaude/ stays loopback-only.
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
# Give an account a cap of its own, below the fleet default (as root on
# som; applies at once and survives restarts, see usageCap below):
#   teamclaude-accounts list
#   teamclaude-accounts cap <name> 80% | unified5h=0.8,unified7d=0.9 | default
#
# Other gateways join the pool as accounts of last resort, declared in
# hyper.teamclaudeGateway.upstreamAccounts: one so far, `fallback`. Each is
# a TeamClaude API-key account whose `upstream` is the other gateway, at
# priority 100, so rotation reaches it only once every own account is past
# its cap, and leaves it as soon as one has quota again. The other gateway
# relays Anthropic's quota headers of whichever of its accounts served the
# request, so its maxUsage reads against those (`fallback`: uncapped; the
# other gateway enforces its own limits). Its URL and key are both prompted
# vars on som, so this repo names
# neither:
#   clan vars generate som --generator teamclaude-fallback-gateway
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
  # Likewise; the non-secret part of each entry goes to preStart as is, the
  # URL and key arrive through the config var.
  upstreamAccounts = lib.mapAttrsToList (name: a: a // { inherit name; }) cfg.upstreamAccounts;
  declaredAccounts = builtins.toJSON (
    map (a: {
      inherit (a) name priority;
      type = "apikey";
      # Both relay to Anthropic, which holds the thread state.
      messageThreads = true;
      inherit (a) maxUsage;
    }) upstreamAccounts
  );
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
  # An account with a cap of its own (teamclaude-accounts cap, kept in
  # capsFile) gets that one instead.
  usageCap = 0.98;
  capsFile = "/var/lib/teamclaude/account-caps.json";
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
  teamclaudeAccounts = pkgs.writeShellScriptBin "teamclaude-accounts" ''
    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      echo "teamclaude-accounts: run as root" >&2
      exit 1
    fi
    exec ${pkgs.util-linux}/bin/runuser -u teamclaude -- \
      ${pkgs.coreutils}/bin/env TEAMCLAUDE_CONFIG=${stateFile} \
      ${pkgs.nodejs}/bin/node ${./accounts.mjs} \
      ${config.services.teamclaude.package}/share/teamclaude/src ${capsFile} ${toString usageCap} "$@"
  '';
in
{
  imports = [
    inputs.teamclaude.nixosModules.default
    ../teamclaude-api-key.nix
    # Its A/AAAA record (hyper.porkbunRecords below).
    ../porkbun-records
    # Usage counters for Grafana (stats.davhau.com).
    ./metrics.nix
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

  options.hyper.teamclaudeGateway.upstreamAccounts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          generator = lib.mkOption {
            type = lib.types.str;
            description = ''
              Clan vars generator with two files: `url`, the other gateway's
              base URL, and `key`, our key for it (sent as x-api-key).
            '';
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 100;
            description = "TeamClaude rotation priority, lower = preferred; own accounts sit at 0.";
          };
          maxUsage = lib.mkOption {
            type = lib.types.nullOr lib.types.float;
            default = usageCap;
            description = "Hard cap on the quota the gateway reports; null = uncapped.";
          };
        };
      }
    );
    default = { };
    description = ''
      Other gateways as accounts of this one: account name -> the var that
      holds where it is and the key. preStart keeps each in `accounts` on every
      start, replacing a live entry of the same name but keeping its runtime
      fields.
    '';
  };

  config = {
    hyper.teamclaudeGateway.clientKeys.hyperconfig = "teamclaude-api-key";

    hyper.teamclaudeGateway.upstreamAccounts.fallback = {
      generator = "teamclaude-fallback-gateway";
      maxUsage = null;
    };

    clan.core.vars.generators = {
      # The fallback gateway: its URL, and our key for it. A persisted prompt
      # IS the file, so each holds exactly the value.
      teamclaude-fallback-gateway.prompts = {
        url = {
          description = "Base URL of the fallback TeamClaude gateway (https://…)";
          type = "hidden";
          persist = true;
        };
        key = {
          description = "Our key for the fallback TeamClaude gateway";
          type = "hidden";
          persist = true;
        };
      };

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
        dependencies = [
          "teamclaude-gateway-key"
        ]
        ++ map (c: c.generator) staticClients
        ++ map (a: a.generator) upstreamAccounts;
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
            ${
              lib.concatImapStringsSep " \\\n  " (
                i: a:
                "--arg an${toString i} ${lib.escapeShellArg a.name} --rawfile ak${toString i} \"$in/${a.generator}/key\" --rawfile au${toString i} \"$in/${a.generator}/url\""
              ) upstreamAccounts
            } \
            '{ proxy: {
                apiKey: ($apiKey | rtrimstr("\n")),
                clientKeys: [ ${
                  lib.concatImapStringsSep ", " (
                    i: _: "{ name: $n${toString i}, key: ($k${toString i} | rtrimstr(\"\\n\")) }"
                  ) staticClients
                } ]
              },
              accounts: [ ${
                lib.concatImapStringsSep ", " (
                  i: _:
                  "{ name: $an${toString i}, apiKey: ($ak${toString i} | rtrimstr(\"\\n\")), upstream: ($au${toString i} | rtrimstr(\"\\n\") | rtrimstr(\"/\")) }"
                ) upstreamAccounts
              } ] }' > "$out/config.json"
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
    # file, except two runtime lists. `accounts` stays as the service left it
    # but for its maxUsage: the account's own cap from capsFile
    # (teamclaude-accounts), else usageCap. The upstreamAccounts are the
    # exception: each is rebuilt from the Nix declaration plus the URL and
    # key from the secret on top of its live entry (which keeps runtime
    # fields such as its id), and gets its own maxUsage unless capsFile has
    # one; a null maxUsage drops the key, which TeamClaude reads as uncapped.
    # `proxy.clientKeys` keeps
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
        caps='{}'
        [ ! -s ${capsFile} ] || caps=$(cat ${capsFile})
        ${pkgs.jq}/bin/jq -s --argjson cap ${builtins.toJSON usageCap} --argjson caps "$caps" \
          --argjson declared ${lib.escapeShellArg declaredAccounts} '
          .[0] as $live
          | (.[2].proxy.clientKeys // []) as $static
          | ([ (.[2].accounts // [])[] | { key: .name, value: { apiKey, upstream } } ] | from_entries) as $secret
          | $live * .[1] * (.[2] | del(.accounts) | del(.proxy.clientKeys))
          | .accounts = (
              [ (.accounts // [])[] | select(.name as $n | $declared | all(.name != $n))
                | .maxUsage = ($caps[.name] // $cap) ]
              + [ $declared[] as $d
                  | ([ ($live.accounts // [])[] | select(.name == $d.name) ][0] // {})
                    + $d + $secret[$d.name]
                  | .maxUsage = ($caps[$d.name] // $d.maxUsage)
                  | if .maxUsage == null then del(.maxUsage) else . end ])
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

    environment.systemPackages = [
      teamclaudeKeys
      teamclaudeAccounts
    ];

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
        # TeamClaude's steering API stays off the public name: the operator
        # uses it on loopback with the operator key. Only GET
        # /teamclaude/status is public (the exact match wins over the 404),
        # still gated by TeamClaude's own check, which accepts any client
        # key there; the anthropic-usage bar widget on amy reads it
        # (../noctalia-anthropic-usage).
        locations."^~ /teamclaude/".return = "404";
        locations."= /teamclaude/status" = {
          proxyPass = "http://127.0.0.1:3456";
          extraConfig = ''
            limit_except GET { deny all; }
            proxy_set_header x-api-key $teamclaude_key;
          '';
        };
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
