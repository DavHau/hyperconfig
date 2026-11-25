# The owner's vault page: https://<front door>/vault/<agent>/, where an
# agent's owner sees what the agent keeps in its vault (label, kind, site,
# login name, created; a card's brand and last 4 digits), reveals a login's
# password on an explicit click (with a copy button) and deletes items.
# https://<dashboard>/vault (and /vault/) answers 302 there, so that is the
# address agents give (./skill).
#
# Why not on the dashboard's host, behind its sign-in like /vault/<id>: the
# dashboard is the agent's own process. Its /api/auth/me (the request
# page's auth subrequest) is answered by code the agent controls (plugins,
# or a server of its own on its backend port), and every dashboard session
# token passes through it. Fine for a page that only adds items; a page that
# hands out passwords must not trust anything the agent can answer or
# replay. So:
#   - the page sits on the front door (sso.frontDoor.host, the deployment's
#     own site), behind the front door's oauth2-proxy (its socket root:nginx,
#     its host-only `__Host-hermes` cookie never sent to an agent's host).
#     nginx passes the account oauth2-proxy vouches for in X-Hermes-Account,
#     always overwritten; the page admits only the agent's owning accounts
#     (sso.accounts.<agent>). No session: a 302 to the front door's sign-in,
#     back to the page afterwards;
#   - it runs per agent as hermes-vault-owner-<agent>, a dynamic user of its
#     own (never the agent's uid), socket-activated on a unix socket only
#     nginx may connect to (root:nginx 0660), exiting after 10 idle minutes;
#   - the values come from the agent's vault broker (../core/vault-broker.py)
#     through owner_list / owner_reveal / owner_remove, which the broker
#     answers only for the main process of this unit (systemd's MainPID,
#     pinned by a pidfd, as its fills), never for any process of the agent
#     or root's. The list carries a card's brand and last 4 only; a reveal
#     only a login's name and password. The broker writes the audit line of
#     every reveal and delete (item id, kind, account; never a value) to its
#     own journal (`journalctl -u hermes-vault-<agent> | grep '^owner-'`;
#     every agent-chosen field the broker logs is reduced to [A-Za-z0-9._@+/-],
#     so no label forges such a line), and caps reveals at 30 an hour. The
#     agent can't delete lines; it can flood the journal into rotation, so
#     retention is journald's, not guaranteed.
# Root's `hermes-vault` CLI (../core/vault-broker.nix) reads the same store
# and writes the same audit line.
#
# The page's defences: exposure's Fetch Metadata gate on the front door
# (cross-site posts refused at nginx), the page's own same-origin check
# (Sec-Fetch-Site, else Origin), a form token per account (HMAC, 2 hours),
# a confirmation step before a delete, nginx's request rate per client
# network, no-store, CSP default-src 'none' (the copy button is the one
# script, by nonce), no framing, no-referrer. Values are only in the
# response of the reveal POST: never in a URL, a log line (the page logs
# nothing; nginx's access log has the request line), a cache or a temp file
# (nginx keeps the small response in memory, proxy_max_temp_file_size 0).
#
# Residual: anyone holding the owner's front-door session (168 h by
# default) can reveal passwords, at most 30 an hour, each audited; the
# agent never holds that session.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  sso = cfg.sso;
  exposure = cfg.exposure;
  ssoLib = import ../../lib/sso.nix { inherit lib; };
  frontDoor = sso.frontDoor.host;
  enabled = lib.filterAttrs (_: a: a.vaultRequest.enable && a.vaultBroker.enable) cfg.agents;
  active = cfg.dashboards.enable && sso.enable && frontDoor != null && enabled != { };
  socketOf = user: "/run/hermes-vault-owner/${user}.sock";
  unitOf = user: "hermes-vault-owner-${user}";
  pathOf = user: "/vault/${user}/";
  pageUrlOf = user: "${exposure.urlOf frontDoor}${pathOf user}";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./owner.py;
  };
in
{
  # The address the agent gives (vault_request action=where, ./plugin): only
  # where the page exists. Per agent in the submodule, as ./default.nix does.
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          config =
            lib.mkIf
              (
                cfg.dashboards.enable
                && sso.enable
                && frontDoor != null
                && config.vaultRequest.enable
                && config.vaultBroker.enable
              )
              {
                environment.HERMES_VAULT_OWNER_PAGE = lib.mkDefault "${config.dashboard.url}/vault";
              };
        }
      )
    );
  };

  config = lib.mkIf active {
    systemd.sockets = lib.mapAttrs' (
      user: _:
      lib.nameValuePair (unitOf user) {
        description = "Owner vault page of ${user}";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ (socketOf user) ];
        socketConfig = {
          SocketUser = "root";
          SocketGroup = config.services.nginx.group;
          SocketMode = "0660";
          DirectoryMode = "0755";
        };
      }
    ) enabled;

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (user: _: {
        # the broker answers the owner operations for this unit's main
        # process only
        "hermes-vault-${user}".environment.BROKER_OWNER_UNIT = "${unitOf user}.service";
        ${unitOf user} = {
          description = "Owner vault page of ${user}";
          requires = [ "${unitOf user}.socket" ];
          wants = [ "hermes-vault-${user}.socket" ];
          after = [ "hermes-vault-${user}.socket" ];
          environment = {
            HERMES_VAULT_AGENT = user;
            HERMES_VAULT_OWNERS = lib.concatStringsSep " " (ssoLib.ownersOf sso.accounts.${user});
            HERMES_VAULT_OWNER_URL = exposure.urlOf frontDoor;
            HERMES_VAULT_DASHBOARD_URL = cfg.agents.${user}.dashboard.url;
            HERMES_VAULT_BROKER_SOCKET = "/run/hermes-vault/${user}.sock";
            PYTHONDONTWRITEBYTECODE = "1";
            PYTHONUNBUFFERED = "1";
          };
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${src}/owner.py";
            DynamicUser = true;
            # its form-token key
            StateDirectory = "hermes-vault-owner/${user}";
            StateDirectoryMode = "0700";
            UMask = "0077";
            # no core dump of a process holding a password
            LimitCORE = 0;
            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateNetwork = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            RestrictNamespaces = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            SystemCallFilter = [ "@system-service" ];
            SystemCallErrorNumber = "EPERM";
            CapabilityBoundingSet = "";
          };
        };
      }) enabled
    );

    services.nginx.appendHttpConfig = ''
      # The owner vault page's rate per client network (../dashboards/ratelimit.js).
      limit_req_zone $hermes_dashboard_client_net zone=hermes_vault_owner:1m rate=30r/m;
    '';

    services.nginx.virtualHosts =
      lib.mapAttrs' (
        user: _:
        lib.nameValuePair "hermes-dashboard-${user}" {
          # The address agents give; nothing of the vault is served here.
          locations."= /vault".return = "302 ${pageUrlOf user}";
          locations."= /vault/".return = "302 ${pageUrlOf user}";
        }
      ) enabled
      // {
        ${frontDoor} = {
          locations =
            lib.mapAttrs' (
              user: _:
              lib.nameValuePair "= ${pathOf user}" {
                proxyPass = "http://unix:${socketOf user}:";
                recommendedProxySettings = false;
                extraConfig = ''
                  # the front door's auth_request (server level, inherited)
                  auth_request_set $hermes_vault_owner_account $upstream_http_x_auth_request_preferred_username;
                  error_page 401 = @hermes_vault_owner_login_${user};
                  proxy_set_header Host $host;
                  proxy_set_header X-Hermes-Account $hermes_vault_owner_account;
                  proxy_set_header X-Forwarded-For "";
                  proxy_set_header Cookie "";
                  proxy_set_header Authorization "";
                  proxy_read_timeout 30s;
                  client_max_body_size 4k;
                  client_body_buffer_size 4k;
                  # A revealed password: kept in nginx's memory, never a temp file.
                  proxy_buffering on;
                  proxy_buffers 8 16k;
                  proxy_buffer_size 16k;
                  proxy_max_temp_file_size 0;
                  limit_req zone=hermes_vault_owner burst=30 nodelay;
                  limit_req_status 429;
                '';
              }
            ) enabled
            # Back to the page after the sign-in: its exact path, a constant
            # (no request variable in the redirect).
            // lib.mapAttrs' (
              user: _:
              lib.nameValuePair "@hermes_vault_owner_login_${user}" {
                extraConfig = ''
                  auth_request off;
                  return 302 ${exposure.urlOf frontDoor}/oauth2/start?rd=${pathOf user};
                '';
              }
            ) enabled;
        };
      };
  };
}
