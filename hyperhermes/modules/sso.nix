# Who may sign in to which agent's web surfaces. hermes' own dashboard
# login (its bundled self-hosted OIDC provider) talks to an OpenID Connect
# issuer; the clients it uses are ../lib/sso.nix's, one per agent.
#
# Public mode: the deployment runs the issuer (`issuer`) and declares
# exactly the clients `oidcClients` lists there (callbacks, groups), handing
# their secrets over as runtime paths (`clients.<id>.secretFile`).
#
# Local mode runs that issuer here: dex with static password users, at
# http://localhost:<port>, not at a name below the domain. hermes accepts
# a plain-HTTP issuer only on the exact host names localhost, 127.0.0.1 and
# ::1 (plugins/dashboard_auth/self_hosted/__init__.py,
# _require_https_or_loopback, v2026.9.14), so http://id.<domain> would
# leave the dashboard without a login provider. Inside this machine
# localhost is nginx's own listener; from a container host, the forwarded
# loopback port lands on the same nginx.
#
# Authorization: each client names the groups it admits (allowedGroups:
# hermes-<agent>; the published ports' client every agent's), and the
# agent's account carries its agent's group. An issuer may enforce that per
# client (pocket-id does); dex has no per-client group restriction and only
# puts the groups into the ID token (`groups` claim, asked for with the
# `groups` scope). So the relying parties check the claim themselves:
# hermes through core's allowed-groups patch (the dashboards module sets
# the group), the front door's and the published ports' oauth2-proxies
# through allowed-group in local mode.
#
# The front door (`frontDoor.host`): an oauth2-proxy (client `hermes`,
# group `hermes`) that features put pages behind (the dashboards module's
# redirect to the account's dashboard). Its login cookie is host-only
# (`__Host-hermes` in public mode; plain `hermes` over local HTTP, where a
# Secure cookie would not stick), so no other name below the front door's
# site can set or overwrite it and it reaches no agent-controlled host.
# oauth2-proxy listens on a unix socket systemd (root) holds for the whole
# uptime (`http-address=fd:3`), root:nginx 0660: no agent talks to it past
# nginx or takes its address while it is down, as it could a loopback port,
# and then answer nginx's auth_request with an account of its choosing.
# Public mode: TLS for the front door and every name below it (other
# features' pages under the deployment's own site) is one DNS-01 wildcard
# certificate, `hermes-subdomains`; with exposure.acme.caa the front door's
# name carries that CAA record.
#
# Secrets are runtime file paths (strings), read by root when dex starts;
# none enters the store. The store config holds placeholders, one per
# secret (@hyperhermes-dex-<kind>-<name>@); dex's pre-start checks each
# file's format and substitutes it into the rendered /run/dex/config.yaml
# (mode 600, dex's own user).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.sso;
  exposure = config.services.hyperhermes.exposure;
  ssoLib = import ../lib/sso.nix { inherit lib; };
  local = exposure.mode == "local";
  dexListen = "127.0.0.1:5556";
  issuerHost = "localhost";

  clients = cfg.oidcClients;
  frontDoor = cfg.frontDoor.host;
  # Local dex: each account's agent groups, the front door's for every
  # agent owner, and any extra ones.
  groups =
    let
      owned = ssoLib.accountGroups cfg.accounts;
    in
    lib.mapAttrs (
      account: u:
      owned.${account} or [ ]
      ++ lib.optional (frontDoor != null && owned ? ${account}) ssoLib.frontDoorGroup
      ++ u.groups
    ) cfg.dex.users;
  frontClient = ssoLib.frontDoorClientId;
  oauth2Socket = "/run/oauth2-proxy.sock";
  frontDoorCert = "hermes-subdomains";

  secretPath =
    description:
    lib.mkOption {
      type = lib.types.str;
      inherit description;
    };
  secretFiles =
    lib.mapAttrsToList (_: c: c.secretFile) cfg.clients
    ++ lib.mapAttrsToList (_: u: u.passwordHashFile) cfg.dex.users
    ++ lib.optional (frontDoor != null) cfg.frontDoor.cookieSecretFile;

  # Placeholder names are client ids and account names; neither may hold
  # the delimiter, so no placeholder is part of another. The formats keep
  # the substituted text inside its YAML scalar and free of placeholders.
  placeholderName = "^[A-Za-z0-9._-]+$";
  clientSecretFormat = "^[A-Za-z0-9._~+/=-]+$";
  bcryptFormat = "^\\$2[aby]\\$[0-9]{2}\\$[./A-Za-z0-9]{53}$";
  clientPlaceholder = id: "@hyperhermes-dex-client-secret-${id}@";
  hashPlaceholder = account: "@hyperhermes-dex-hash-${account}@";
  substitutions =
    lib.mapAttrsToList (account: u: {
      placeholder = hashPlaceholder account;
      file = u.passwordHashFile;
      format = bcryptFormat;
      what = "bcrypt hash";
    }) cfg.dex.users
    ++ lib.mapAttrsToList (id: c: {
      placeholder = clientPlaceholder id;
      file = c.secretFile;
      format = clientSecretFormat;
      what = "client secret (one line of ${clientSecretFormat})";
    }) cfg.clients;
  # Runs as root after the dex module's pre-start, which installs the
  # store config at /run/dex/config.yaml.
  substituteSecrets = pkgs.writeShellScript "hyperhermes-dex-secrets" ''
    set -eu
    check() {
      local value
      value=$(< "$1")
      if [[ ! $value =~ $2 ]]; then
        echo "hyperhermes-dex: $1 is not a $3" >&2
        exit 1
      fi
    }
    ${lib.concatMapStrings (s: ''
      check ${
        lib.escapeShellArgs [
          s.file
          s.format
          s.what
        ]
      }
      ${pkgs.replace-secret}/bin/replace-secret ${
        lib.escapeShellArgs [
          s.placeholder
          s.file
          "/run/dex/config.yaml"
        ]
      }
    '') substitutions}
  '';
in
{
  options.services.hyperhermes.sso = {
    enable = lib.mkEnableOption "OIDC login for the agents' web surfaces";

    issuer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        OIDC issuer URL hermes and the proxies log in against. Local mode
        defaults it to the dex it runs; public mode names the deployment's
        identity provider (https: hermes refuses anything else off
        loopback).
      '';
    };

    frontDoor = {
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "hermes.example.com";
        description = ''
          Host name of the front door (the header), or null for none. Public
          mode: a name of the deployment's own site, never below
          exposure.domain (agent-controlled).
        '';
      };
      cookieSecretFile = lib.mkOption {
        type = lib.types.str;
        description = "Runtime path of the front door's oauth2-proxy cookie secret: 16, 24 or 32 bytes, raw or in URL-safe base64 (oauth2-proxy decodes no other base64).";
      };
    };

    oidcClients = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      description = ''
        The clients this deployment logs in with (../lib/sso.nix): id ->
        { name, callbackURLs, pkce, allowedGroups }. A deployment with its
        own issuer declares exactly these there (the published ports'
        client may use one host-pattern callback per agent instead of the
        exact ones listed here, where the issuer takes patterns:
        lib.sso.oidcClients without publishHosts).
      '';
    };

    publishHosts = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf (lib.types.listOf lib.types.str));
      default = null;
      internal = true;
      description = "Set by the publish module: agent -> its private port hosts, whose callbacks the client hermes-serve lists. Null: no published ports.";
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "agent -> the login account that owns it.";
    };

    clients = lib.mkOption {
      default = { };
      description = "Secrets of the OIDC clients ../lib/sso.nix declares, by client id.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.secretFile = secretPath "Runtime path of the client secret.";
        }
      );
    };

    dex.users = lib.mkOption {
      default = { };
      description = "Local mode: the dex password users, by login account.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              email = lib.mkOption {
                type = lib.types.str;
                default = "${name}@${exposure.domain}";
                description = "Login name on dex's password form.";
              };
              passwordHashFile = secretPath "Runtime path of the account's bcrypt password hash.";
              groups = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Groups beyond the ones the account's agents (and the front door) give it.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkMerge [
    {
      services.hyperhermes.sso.oidcClients = ssoLib.oidcClients {
        inherit (exposure) domain;
        inherit (cfg) accounts publishHosts;
        originOf = exposure.urlOf;
        frontDoor = cfg.frontDoor.host;
        publish = cfg.publishHosts != null;
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.issuer != null;
          message = "services.hyperhermes.sso.issuer must name the OIDC issuer (local mode sets it to its dex).";
        }
        {
          assertion = exposure.enable;
          message = "services.hyperhermes.sso needs services.hyperhermes.exposure.enable.";
        }
        {
          assertion = lib.all (n: cfg.accounts ? ${n}) (lib.attrNames config.services.hyperhermes.agents);
          message = "services.hyperhermes.sso.accounts must name the owning account of every agent.";
        }
        {
          assertion = lib.attrNames cfg.clients == lib.attrNames clients;
          message = "services.hyperhermes.sso.clients must give the secret of exactly the clients ${toString (lib.attrNames clients)}.";
        }
        {
          assertion = !local || lib.all (a: cfg.dex.users ? ${a}) (lib.attrValues cfg.accounts);
          message = "services.hyperhermes.sso.dex.users must declare every account of services.hyperhermes.sso.accounts.";
        }
        {
          assertion = lib.all (f: !lib.hasPrefix builtins.storeDir f) secretFiles;
          message = "services.hyperhermes.sso: secret files must be runtime paths outside the Nix store.";
        }
        {
          assertion = lib.all (n: builtins.match placeholderName n != null) (
            lib.attrNames clients ++ lib.attrNames cfg.dex.users
          );
          message = "services.hyperhermes.sso: agent and account names must match ${placeholderName}.";
        }
        {
          assertion = frontDoor != null -> !lib.hasSuffix ".${exposure.domain}" ".${frontDoor}";
          message = "services.hyperhermes.sso.frontDoor.host must not be ${exposure.domain} or below it: that site is agent-controlled.";
        }
      ];
    })

    (lib.mkIf (cfg.enable && frontDoor != null) {
      services.oauth2-proxy = {
        enable = true;
        provider = "oidc";
        oidcIssuerUrl = cfg.issuer;
        clientID = frontClient;
        clientSecretFile = cfg.clients.${frontClient}.secretFile;
        cookie = {
          # Host-only by browser rule: no Domain, Secure, Path=/ (the
          # header). Over local HTTP no Secure cookie sticks.
          name = if local then "hermes" else "__Host-hermes";
          secure = !local;
          secretFile = cfg.frontDoor.cookieSecretFile;
        };
        redirectURL = "${exposure.urlOf frontDoor}/oauth2/callback";
        email.domains = [ "*" ];
        setXauthrequest = true;
        reverseProxy = true;
        # The socket systemd holds (the header).
        httpAddress = "fd:3";
        # No TCP peer can reach it; peers of the unix socket (nginx) are
        # trusted regardless. Narrow anyway, or oauth2-proxy trusts every
        # address.
        trustedProxyIP = [ "127.0.0.1" ];
        extraConfig = {
          # Accounts may have no email; identify them by username instead.
          oidc-email-claim = "preferred_username";
          insecure-oidc-allow-unverified-email = true;
          code-challenge-method = "S256";
          skip-provider-button = true;
          # Back to the page asked for after the sign-in, on this host only.
          whitelist-domain = frontDoor;
        }
        // lib.optionalAttrs local {
          # dex admits every account to every client (the header).
          allowed-group = ssoLib.frontDoorGroup;
        };
        scope = lib.mkIf local "openid email profile groups";
        nginx = {
          domain = frontDoor;
          proxy = "http://unix:${oauth2Socket}:";
          virtualHosts.${frontDoor} = { };
        };
      };

      services.nginx.virtualHosts.${frontDoor} = exposure.virtualHost frontDoorCert;

      systemd.sockets.oauth2-proxy = {
        description = "Socket of the hermes front door's oauth2-proxy";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ oauth2Socket ];
        # While the issuer is unreachable the proxy fails at start, and the
        # requests queued on the socket keep activating it; the default
        # trigger limit (20 activations per 2s) would put the socket into
        # the failed state, where it stays after the issuer is back.
        # TriggerLimitIntervalSec=0 disables it (systemd.socket(5)). The
        # restarts still wait RestartSec: the socket starts no service that
        # is waiting to restart (systemd counts that as activating already).
        socketConfig = {
          TriggerLimitIntervalSec = 0;
          SocketUser = "root";
          SocketGroup = config.services.nginx.group;
          SocketMode = "0660";
        };
      };
      # OIDC discovery needs DNS for the issuer, and network-online.target
      # promises nothing where the wait-online services are masked. The
      # stock Restart=always at 100ms burnt the start limit within a second
      # of boot and left the front door down; retry every 5s, indefinitely,
      # until the issuer resolves and answers. Requests wait on the socket
      # meanwhile.
      systemd.services.oauth2-proxy = {
        requires = [ "oauth2-proxy.socket" ];
        after = [ "oauth2-proxy.socket" ];
        serviceConfig.RestartSec = "5s";
        unitConfig.StartLimitIntervalSec = 0;
      };
    })

    (lib.mkIf (cfg.enable && frontDoor != null && !local) {
      # The front door and its subdomains (the header), DNS-01 only.
      security.acme.certs.${frontDoorCert} = exposure.acmeCert "*.${frontDoor}" // {
        extraDomainNames = [ frontDoor ];
      };
      services.hyperhermes.exposure.records = lib.mkIf (exposure.acme.caa != null) {
        ${frontDoor}.CAA = exposure.acme.caa;
      };
    })

    (lib.mkIf (cfg.enable && local) {
      services.hyperhermes.sso.issuer = lib.mkDefault (exposure.urlOf issuerHost);

      services.dex = {
        enable = true;
        settings = {
          inherit (cfg) issuer;
          storage = {
            type = "sqlite3";
            config.file = "/var/lib/dex/dex.db";
          };
          web.http = dexListen;
          enablePasswordDB = true;
          oauth2.skipApprovalScreen = true;
          # Secrets are placeholders, substituted below. Not the dex
          # module's secretFile: it uses the path itself as the placeholder,
          # and one path can be part of another.
          staticClients = lib.mapAttrsToList (id: c: {
            inherit id;
            inherit (c) name;
            redirectURIs = c.callbackURLs;
            secret = clientPlaceholder id;
          }) clients;
          staticPasswords = lib.mapAttrsToList (account: u: {
            inherit (u) email;
            username = account;
            userID = account;
            preferredUsername = account;
            hash = hashPlaceholder account;
            groups = groups.${account};
          }) cfg.dex.users;
        };
      };

      systemd.services.dex.serviceConfig = {
        StateDirectory = "dex";
        # After the module's own pre-start, which installs the config.
        ExecStartPre = lib.mkAfter [ "+${substituteSecrets}" ];
      };

      services.nginx.virtualHosts.hermes-dex = {
        serverName = issuerHost;
        listen = exposure.nginxListen;
        locations."/".proxyPass = "http://${dexListen}";
      };
    })
  ];
}
