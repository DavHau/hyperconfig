# Pocket ID as the clan's OpenID Connect provider.
#
# roles.server (one machine): runs pocket-id behind nginx at `appUrl`, keeps
#   the porkbun A/AAAA record of that host current, and reconciles the
#   instance with the declared state on every activation
#   (pocket-id-reconcile.py): user groups, users, OIDC clients with their
#   allowed groups and secrets, logo/favicon. Groups and clients are fully
#   declarative; users are created/updated but never deleted (passkeys are
#   not reproducible). The app config is env-only (UI_CONFIG_DISABLED), so
#   nothing drifts through the admin UI.
# roles.client (any machine): declares the OIDC clients it consumes in its
#   inventory settings. The server sees every client role's settings, so
#   no machine evaluates another's nixosConfiguration. The role exposes
#   `hyper.oidc.issuer` and `hyper.oidc.clients.<id>.{clientId,secretFile}`
#   for the machine's own modules (nextcloud, vikunja, hermes dashboards).
#
# A confidential client's secret is one shared clan var
# (`oidc-client-<id>`) declared by both roles: the consumer reads it, the
# server installs it into pocket-id (identified by its 4-char clear-text
# prefix). Every client must name at least one allowed group: pocket-id
# treats "no groups" as "everyone".
#
# Enrollment: `pocket-id-enroll <username>` on the server prints a one-time
# login link; the person registers a passkey through it.
{ ... }:
let
  clientModule =
    { lib, config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          description = "Display name of the client (consent screen, admin UI).";
        };
        callbackURLs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "Exact redirect URIs the client may use.";
        };
        logoutCallbackURLs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Post-logout redirect URIs.";
        };
        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Public client: PKCE only, no client secret is generated.";
        };
        pkce = lib.mkOption {
          type = lib.types.bool;
          default = config.public;
          defaultText = "public";
          description = "Require PKCE. Always on for public clients; a confidential relying party may not support it (vikunja).";
        };
        allowedGroups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "User groups whose members may log in to this client. Must be non-empty.";
        };
      };
    };

  clientsOption =
    lib: description:
    lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule clientModule);
      default = { };
      inherit description;
    };

  # Declared identically on the server and on every consumer. Root-owned;
  # services receive the value through systemd LoadCredential.
  secretGenerator =
    pkgs: id:
    {
      "oidc-client-${id}" = {
        share = true;
        files.secret = { };
        runtimeInputs = [
          pkgs.coreutils
          pkgs.openssl
        ];
        script = ''
          openssl rand -base64 48 | tr -d '\n' > "$out"/secret
        '';
      };
    };

  confidential = clients: builtins.filter (id: !clients.${id}.public) (builtins.attrNames clients);
in
{
  _class = "clan.service";
  manifest.name = "hyperconfig/oidc";
  manifest.description = "Pocket ID OpenID Connect provider with declaratively reconciled users, groups and clients";
  manifest.categories = [ "System" ];

  roles.server = {
    description = "Runs pocket-id and reconciles it with the declared users, groups and every client role's clients.";

    interface =
      { lib, ... }:
      {
        options = {
          appUrl = lib.mkOption {
            type = lib.types.str;
            example = "https://id.example.com";
            description = "Public https URL (= OIDC issuer). Its host becomes the nginx vhost and the porkbun record.";
          };
          appName = lib.mkOption {
            type = lib.types.str;
            description = "Name shown on the login page.";
          };
          logo = lib.mkOption {
            type = lib.types.path;
            description = "PNG used as light logo, dark logo and favicon.";
          };
          users = lib.mkOption {
            default = { };
            description = "Accounts to create. Passkeys are enrolled by the person via pocket-id-enroll.";
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  email = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                  };
                  displayName = lib.mkOption { type = lib.types.str; };
                  admin = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                  };
                  groups = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                  };
                };
              }
            );
          };
          groups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Groups beyond those referenced by clients and users.";
          };
          extraClients = clientsOption lib "Clients with no clan machine behind them (e.g. a SaaS relying party).";
        };
      };

    perInstance =
      { roles, settings, ... }:
      {
        nixosModule =
          {
            config,
            lib,
            pkgs,
            options,
            ...
          }:
          let
            perMachine = lib.mapAttrs (_: m: m.settings.clients) (roles.client.machines or { });
            clients = lib.foldl' (acc: cs: acc // cs) settings.extraClients (lib.attrValues perMachine);
            declaredTwice = lib.filter (id: (lib.count (cs: cs ? ${id}) (lib.attrValues perMachine ++ [ settings.extraClients ])) > 1) (
              lib.attrNames clients
            );
            groups = lib.unique (
              settings.groups
              ++ lib.concatMap (c: c.allowedGroups) (lib.attrValues clients)
              ++ lib.concatMap (u: u.groups) (lib.attrValues settings.users)
            );
            desiredState = pkgs.writeText "pocket-id-desired-state.json" (
              builtins.toJSON {
                inherit groups;
                users = settings.users;
                clients = lib.mapAttrs (_: c: {
                  inherit (c)
                    name
                    callbackURLs
                    logoutCallbackURLs
                    public
                    pkce
                    allowedGroups
                    ;
                }) clients;
              }
            );
            host = (lib.elemAt (lib.splitString "/" settings.appUrl) 2);
            hostLabels = lib.splitString "." host;
            zone = lib.concatStringsSep "." (lib.sublist (lib.length hostLabels - 2) 2 hostLabels);
            sub = lib.concatStringsSep "." (lib.sublist 0 (lib.length hostLabels - 2) hostLabels);
            gen = config.clan.core.vars.generators.pocket-id;
            port = 1411;
            enroll = pkgs.writeShellApplication {
              name = "pocket-id-enroll";
              runtimeInputs = [ pkgs.systemd ];
              runtimeEnv = {
                POCKET_ID_BIN = lib.getExe config.services.pocket-id.package;
                POCKET_ID_DATA_DIR = config.services.pocket-id.dataDir;
                # [ environmentFile settingsFile ] in the nixpkgs module.
                POCKET_ID_ENV_FILE = lib.last config.systemd.services.pocket-id.serviceConfig.EnvironmentFile;
                POCKET_ID_ENCRYPTION_KEY_FILE = gen.files.encryption_key.path;
              };
              text = builtins.readFile ./pocket-id-enroll.sh;
            };
          in
          {
            assertions = [
              {
                assertion = lib.length (lib.attrNames roles.server.machines) == 1;
                message = "oidc: exactly one server machine is supported.";
              }
              {
                assertion = declaredTwice == [ ];
                message = "oidc: client id(s) declared by more than one machine: ${toString declaredTwice}";
              }
              {
                assertion = lib.hasPrefix "https://" settings.appUrl;
                message = "oidc: appUrl must be https:// (WebAuthn needs a secure origin).";
              }
            ]
            ++ lib.mapAttrsToList (id: c: {
              assertion = c.allowedGroups != [ ];
              message = "oidc: client ${id} has no allowedGroups; pocket-id would let every account in.";
            }) clients
            ++ lib.mapAttrsToList (name: u: {
              assertion = lib.all (g: lib.elem g groups) u.groups;
              message = "oidc: user ${name} references an unknown group.";
            }) settings.users;

            clan.core.vars.generators = {
              pocket-id = {
                files.encryption_key = { };
                files.api_key = { };
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.openssl
                ];
                script = ''
                  openssl rand -base64 32 | tr -d '\n' > "$out"/encryption_key
                  openssl rand -hex 32 | tr -d '\n' > "$out"/api_key
                '';
              };
            }
            // lib.foldl' (acc: id: acc // secretGenerator pkgs id) { } (confidential clients);

            services.pocket-id = {
              enable = true;
              settings = {
                APP_URL = settings.appUrl;
                TRUST_PROXY = true;
                HOST = "127.0.0.1";
                PORT = port;
                UI_CONFIG_DISABLED = true;
                APP_NAME = settings.appName;
                # We create the accounts ourselves; a verified email is what
                # consumers (vikunja) need to link by email.
                EMAILS_VERIFIED = true;
                # Accounts may be declared without an email.
                REQUIRE_USER_EMAIL = false;
                ANALYTICS_DISABLED = true;
                VERSION_CHECK_DISABLED = true;
              };
              credentials = {
                ENCRYPTION_KEY = gen.files.encryption_key.path;
                STATIC_API_KEY = gen.files.api_key.path;
              };
            };

            systemd.services.pocket-id-reconcile = {
              description = "Reconcile pocket-id with the declared users, groups and clients";
              after = [ "pocket-id.service" ];
              requires = [ "pocket-id.service" ];
              wantedBy = [ "multi-user.target" ];
              restartTriggers = [
                desiredState
                settings.logo
              ];
              environment = {
                POCKET_ID_URL = "http://127.0.0.1:${toString port}";
                DESIRED_STATE = desiredState;
                LOGO = settings.logo;
              };
              serviceConfig = {
                Type = "oneshot";
                DynamicUser = true;
                LoadCredential = [
                  "api_key:${gen.files.api_key.path}"
                ]
                ++ map (id: "client-${id}:${config.clan.core.vars.generators."oidc-client-${id}".files.secret.path}") (
                  confidential clients
                );
                ExecStart = "${pkgs.python3.interpreter} ${./pocket-id-reconcile.py}";
                CapabilityBoundingSet = "";
                LockPersonality = true;
                NoNewPrivileges = true;
                PrivateDevices = true;
                PrivateTmp = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                RestrictAddressFamilies = [
                  "AF_INET"
                  "AF_INET6"
                ];
                RestrictNamespaces = true;
                SystemCallArchitectures = "native";
              };
            };

            environment.systemPackages = [ enroll ];

            networking.firewall.allowedTCPPorts = [
              80
              443
            ];
            security.acme = {
              acceptTerms = true;
              defaults.email = lib.mkDefault "info@${zone}";
            };
            services.nginx = {
              enable = true;
              recommendedProxySettings = true;
              virtualHosts.${host} = {
                forceSSL = true;
                enableACME = true;
                locations."/".proxyPass = "http://127.0.0.1:${toString port}";
              };
            };

            # Keep the public record on the machine's own addresses
            # (modules/nixos/dyndns-porkbun.nix; only where it is imported).
            services.porkbun = lib.mkIf (options.services ? porkbun) {
              ipv4Entries = [ "${zone}/A/${sub}" ];
              ipv6Entries = [ "${zone}/AAAA/${sub}" ];
            };
          };
      };
  };

  roles.client = {
    description = "Consumes the provider: declares its OIDC clients, receives the issuer and client secrets.";

    interface =
      { lib, ... }:
      {
        options.clients = clientsOption lib "OIDC clients this machine's services use; the id is the client_id.";
      };

    perInstance =
      { roles, settings, ... }:
      {
        nixosModule =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            server = lib.head (lib.attrValues roles.server.machines);
          in
          {
            options.hyper.oidc = {
              issuer = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                description = "OIDC issuer URL of the clan's pocket-id.";
              };
              clients = lib.mkOption {
                readOnly = true;
                description = "Clients declared for this machine, with their resolved secret file.";
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    options = {
                      clientId = lib.mkOption { type = lib.types.str; };
                      public = lib.mkOption { type = lib.types.bool; };
                      secretFile = lib.mkOption { type = lib.types.nullOr lib.types.path; };
                      callbackURLs = lib.mkOption { type = lib.types.listOf lib.types.str; };
                      allowedGroups = lib.mkOption { type = lib.types.listOf lib.types.str; };
                    };
                  }
                );
              };
            };

            config = {
              hyper.oidc.issuer = server.settings.appUrl;
              hyper.oidc.clients = lib.mapAttrs (id: c: {
                clientId = id;
                inherit (c) public callbackURLs allowedGroups;
                secretFile =
                  if c.public then null else config.clan.core.vars.generators."oidc-client-${id}".files.secret.path;
              }) settings.clients;

              clan.core.vars.generators = lib.foldl' (acc: id: acc // secretGenerator pkgs id) { } (
                confidential settings.clients
              );
            };
          };
      };
  };
}
