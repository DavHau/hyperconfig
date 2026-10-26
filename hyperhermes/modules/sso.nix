# Who may sign in to which agent's web surfaces. hermes' own dashboard
# login (its bundled self-hosted OIDC provider) talks to an OpenID Connect
# issuer; the clients it uses are ../lib/sso.nix's, one per agent.
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
# Authorization: each client names the one group it admits (allowedGroups,
# hermes-<agent>), and the agent's account carries that group. dex has no
# per-client group restriction, so it only puts the groups into the ID
# token (`groups` claim, asked for with the `groups` scope); hermes reads
# that claim but does not restrict on it either (v2026.9.14), so in local
# mode any configured account can sign in to any agent's dashboard.
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

  clients = ssoLib.oidcClients {
    inherit (exposure) domain;
    inherit (cfg) accounts;
    originOf = exposure.urlOf;
  };
  groups = ssoLib.accountGroups cfg.accounts;

  secretPath =
    description:
    lib.mkOption {
      type = lib.types.str;
      inherit description;
    };
  secretFiles =
    lib.mapAttrsToList (_: c: c.secretFile) cfg.clients
    ++ lib.mapAttrsToList (_: u: u.passwordHashFile) cfg.dex.users;

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
        defaults it to the dex it runs; otherwise the deployment names its
        identity provider.
      '';
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
            };
          }
        )
      );
    };
  };

  config = lib.mkMerge [
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
      ];
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
            hash = hashPlaceholder account;
            groups = groups.${account} or [ ];
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
