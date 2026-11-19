# vault-request: an agent asks its owner for a missing vault item (a
# payment card, a site login, an address) through a one-time link to a
# page behind the agent's own dashboard sign-in, never in chat. Works from
# every channel the agent talks on (Telegram, WhatsApp, the dashboard): the
# link is plain text.
#
# Hermes' own ways in stop short of this (hermes v0.23.0): `hermes vault
# add` needs a terminal on the host, the desktop app's Settings > Credential
# Vault a desktop connection, and browser_vault's in-chat prompts
# (gateway/session_vault_prompt.py) cover logins and one-time codes only,
# for local desktop/TUI viewers. Upstream has no request-link feature;
# NousResearch/hermes-agent#148310 (open) adds a dashboard Vault page,
# which would not reach a chat on Telegram either.
#
# The pieces, per agent with vaultRequest.enable (default: every agent with
# a dashboard and without lockedConfig):
#   - the `vault-request` hermes plugin (./plugin), linked into the agent's
#     plugins/ and enabled: the `vault_request` tool. `create` writes a
#     request (kind, label, origin, the agent's reason; no secret) into
#     <stateDir>/vault-requests (0700 the agent, files 0600): 128-bit id,
#     its own form token, 30 minutes, single use, bound to the profile home
#     the session runs in. It returns https://<dashboard>/vault/<id>.
#     `wait` polls until the user saved it and returns the item's handle,
#     which browser_vault fills with.
#   - the page (./service.py), socket-activated per agent as the agent's
#     uid (the vault is the agent's: hermes' VaultStore.add_item writes it,
#     the store `hermes vault add` and the desktop app write), on a unix
#     socket only nginx may connect to (root:nginx 0660), exiting after 10
#     idle minutes.
#   - nginx, on the agent's dashboard host: /vault/<id> goes to that
#     agent's socket only after an auth subrequest to its dashboard's
#     /api/auth/me with the access-token cookie alone (as infra-space's
#     clan-secret-prompt page: never the refresh token, whose rotation in a
#     subrequest would end the session). No session: a 302 to the
#     dashboard's sign-in, back to the page afterwards. So exactly the
#     dashboard's members reach it: hermes checks the token's audience
#     (hermes-<agent>) and the group (hermes-<agent>), and its __Host-
#     cookies reach no other agent's host.
#   - the `vault-request` skill: when to send a link and what to say.
#
# Card data at rest: hermes' encrypted vault, <HERMES_HOME>/vault/
# vault.json.enc (Fernet), the key in vault.key beside it (0600, the
# agent's 0700 home), or the OS keychain with vault.key_storage: keychain.
# The agent's uid can read both, as it always could: the vault keeps values
# out of the model's context, the session and the logs, not away from the
# agent's own processes.
#
# The page's defences: Fetch Metadata (exposure's gate refuses cross-site
# posts at nginx; the page itself wants Sec-Fetch-Site same-origin, or
# without Fetch Metadata an Origin equal to the dashboard's), the form
# token, single use under a lock, 5 failed submissions end a request, at
# most 10 pending per agent, expiry, a 16 KiB body kept in nginx's memory
# (never a temp file), its own request rate, no-store, CSP default-src
# 'none' with form-action 'self', no framing, no-referrer, nothing loaded
# from anywhere. Values travel in the POST body only: never in a URL, a log
# line (the page logs nothing but an id prefix and the state; nginx's
# access log has the request line), a response or a file of ours.
#
# What the agent's owner cannot be protected from here: a prompt-injected
# agent asking for a card it has no business with. The page names the kind,
# the site the item will be filled on (browser_vault fills it there only,
# and asks the user before every card fill) and the agent's reason, and
# says to continue only if expected.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  dashboards = cfg.dashboards;
  exposure = cfg.exposure;
  hlib = import ../../lib/core.nix { inherit lib; };
  public = exposure.mode == "public";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./service.py
      ./plugin/plugin.yaml
      ./plugin/__init__.py
      ./plugin/common.py
    ];
  };
  skill = import ../../lib/agent-skill.nix pkgs {
    name = "vault-request";
    src = lib.fileset.toSource {
      root = ./skill;
      fileset = ./skill/SKILL.md;
    };
  };

  requestDirOf = user: "${hlib.stateDir user}/vault-requests";
  socketOf = user: "/run/hermes-vault-request/${user}.sock";
  enabled = lib.filterAttrs (_: a: a.vaultRequest.enable) cfg.agents;
  active = dashboards.enable && enabled != { };
in
{
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        {
          options.vaultRequest.enable = lib.mkOption {
            type = lib.types.bool;
            default = dashboards.enable && !config.lockedConfig;
            defaultText = lib.literalMD "`dashboards.enable` and not `lockedConfig`";
            description = ''
              The vault_request tool and its page at <dashboard>/vault/<id>:
              the agent asks its owner for a missing card, login or address
              through a one-time link, and the values go straight into its
              encrypted vault.
            '';
          };
          config = lib.mkIf (dashboards.enable && config.vaultRequest.enable) {
            settings.plugins.enabled = [ "vault-request" ];
            environment = lib.mapAttrs (_: lib.mkDefault) {
              HERMES_VAULT_REQUEST_DIR = requestDirOf name;
              HERMES_VAULT_REQUEST_URL = config.dashboard.url;
            };
            skillDirs = [ "${skill}/share/skills" ];
          };
        }
      )
    );
  };

  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList (user: a: {
        assertion = !a.lockedConfig;
        message = "services.hyperhermes.agents.${user}: vaultRequest links a plugin into the agent's plugins/, which lockedConfig makes root's; set vaultRequest.enable = false.";
      }) enabled;
    }

    (lib.mkIf active {
      systemd.tmpfiles.rules = lib.mapAttrsToList (
        user: _: "d ${requestDirOf user} 0700 ${user} users - -"
      ) enabled;

      systemd.sockets = lib.mapAttrs' (
        user: _:
        lib.nameValuePair "hermes-vault-request-${user}" {
          description = "Vault request page of ${user}";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ (socketOf user) ];
          socketConfig = {
            SocketUser = "root";
            SocketGroup = "nginx";
            SocketMode = "0660";
            DirectoryMode = "0755";
          };
        }
      ) enabled;

      systemd.services = lib.mkMerge (
        lib.mapAttrsToList (user: _: {
          # Hermes discovers user plugins only under $HERMES_HOME/plugins:
          # in the home and in each named profile (a home of its own, whose
          # requests name it, see service.py _home_of); renewed before every
          # start, after core's preStart made the dir. A real directory in
          # the link's place would make `ln -sfn` link inside it: it goes
          # (only plugin code, as camofox's).
          "hermes-agent-${user}".preStart = lib.mkAfter ''
            for home in ${hlib.stateDir user}/.hermes ${hlib.stateDir user}/.hermes/profiles/*/; do
              [ -d "$home" ] || continue
              plugins=''${home%/}/plugins
              mkdir -p "$plugins"
              if [ -d "$plugins/vault-request" ] && [ ! -L "$plugins/vault-request" ]; then rm -rf "$plugins/vault-request"; fi
              ln -sfn ${src}/plugin "$plugins/vault-request"
            done
          '';
          "hermes-vault-request-${user}" = {
            description = "Vault request page of ${user}";
            requires = [ "hermes-vault-request-${user}.socket" ];
            unitConfig.RequiresMountsFor = [ (hlib.stateDir user) ];
            # The dashboard's HOME, HERMES_HOME and managed config dir.
            environment = lib.getAttrs [ "HOME" "HERMES_HOME" "HERMES_MANAGED_DIR" ] config.systemd.services."hermes-dashboard-${user}".environment // {
              HERMES_VAULT_REQUEST_DIR = requestDirOf user;
              HERMES_VAULT_REQUEST_URL = cfg.agents.${user}.dashboard.url;
              PYTHONDONTWRITEBYTECODE = "1";
              PYTHONUNBUFFERED = "1";
            };
            serviceConfig = {
              User = user;
              Group = "users";
              ExecStart = "${cfg.package.hermesVenv}/bin/python3 ${src}/service.py";
              UMask = "0077";
              # no core dump of a process holding a card
              LimitCORE = 0;
              NoNewPrivileges = true;
              PrivateTmp = true;
              PrivateNetwork = true;
              ProtectSystem = "strict";
              ProtectHome = "read-only";
              ReadWritePaths = [
                "-${hlib.stateDir user}/.hermes"
                "-${requestDirOf user}"
              ];
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;
              ProtectClock = true;
              ProtectHostname = true;
              PrivateDevices = true;
              ProtectProc = "invisible";
              ProcSubset = "pid";
              RestrictRealtime = true;
              SystemCallArchitectures = "native";
              LockPersonality = true;
              RestrictSUIDSGID = true;
              RestrictNamespaces = true;
              RestrictAddressFamilies = [ "AF_UNIX" ];
              SystemCallFilter = [ "@system-service" ];
              SystemCallErrorNumber = "EPERM";
              CapabilityBoundingSet = "";
            };
          };
        }) enabled
      );

      services.nginx.appendHttpConfig = ''
        # The page's own rate per agent host and client network
        # (../dashboards/ratelimit.js): opening the form, sending it, a
        # few corrections.
        limit_req_zone "$hermes_dashboard_client_net $host" zone=hermes_vault_request:1m rate=20r/m;
        # The access-token cookie alone for the page's auth subrequest: the
        # __Host- one over HTTPS (as hermes sets it), else the bare one
        # (local mode's plain HTTP). Never a bare one beside a __Host- one:
        # a sibling host may toss a stale bare cookie in front.
        map $http_cookie $hermes_vault_request_at_host {
          "~(?:^|;)\s*(?<at>__Host-hermes_session_at=[^;\s]+)" $at;
          default "";
        }
        map $http_cookie $hermes_vault_request_at_bare {
          "~(?:^|;)\s*(?<at>hermes_session_at=[^;\s]+)" $at;
          default "";
        }
        map $hermes_vault_request_at_host $hermes_vault_request_session {
          "" ${if public then "\"\"" else "$hermes_vault_request_at_bare"};
          default $hermes_vault_request_at_host;
        }
      '';

      services.nginx.virtualHosts = lib.mapAttrs' (
        user: _:
        lib.nameValuePair "hermes-dashboard-${user}" {
          # (no `{32}`: a brace would end nginx's location line; the page
          # takes exactly 32)
          locations."~ ^/vault/(?<hermes_vault_request_id>[0-9a-f]+)$" = {
            proxyPass = "http://unix:${socketOf user}:";
            recommendedProxySettings = false;
            extraConfig = ''
              auth_request /_hermes_vault_request_auth;
              error_page 401 = @hermes_vault_request_login;
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_set_header Cookie "";
              proxy_set_header Authorization "";
              proxy_read_timeout 60s;
              # The body holds the card: nginx keeps it in memory whole,
              # never in a temp file (a body beyond client_body_buffer_size
              # would be spooled to client_body_temp_path in plaintext).
              client_max_body_size 16k;
              client_body_buffer_size 16k;
              client_body_in_file_only off;
              limit_req zone=hermes_vault_request burst=10 nodelay;
              limit_req_status 429;
            '';
          };
          locations."= /_hermes_vault_request_auth" = {
            proxyPass = "http://127.0.0.1:${toString (hlib.dashboardPortFor user)}/api/auth/me";
            recommendedProxySettings = false;
            extraConfig = ''
              internal;
              proxy_method GET;
              proxy_pass_request_body off;
              proxy_set_header Content-Length "";
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_set_header X-Forwarded-Proto ${if public then "https" else "http"};
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Prefix "";
              proxy_set_header Forwarded "";
              proxy_set_header Authorization "";
              # cookie-only on purpose: no gateway ticket either
              proxy_set_header X-Hermes-Gateway-Ticket "";
              proxy_set_header X-Hermes-Session-Token "";
              proxy_set_header Cookie $hermes_vault_request_session;
            '';
          };
          # Straight into the dashboard's OIDC sign-in, back to the page.
          # Also when only the access token expired: the subrequest never
          # refreshes (that would rotate the refresh token without the
          # browser seeing the new one); the identity provider's own session
          # makes the round trip quick.
          locations."@hermes_vault_request_login".extraConfig = ''
            return 302 /auth/login?provider=self-hosted&next=/vault/$hermes_vault_request_id;
          '';
        }
      ) enabled;
    })
  ];
}
