# Public web dashboards for native hermes agents, one shared vhost:
# https://<host>/<user>/ (AAAA -> this host's stable public v6,
# networking.publicIPv6Token) -> nginx (ACME) -> the user's native
# dashboard backend on 127.0.0.1:20000+uid. A user may keep an older
# dedicated hostname (`legacyHost`, served at its root) for links in the
# wild; both front the same backend and session.
#
# Clan-internal mirror at http://<internalHost>/hermes/<user>/
# (<machine>.<clan domain>, yggdrasil IPv6 from the clan /etc/hosts):
# plain HTTP, since nothing can issue certificates for the private zone
# and yggdrasil already encrypts end to end. Same backends, same login;
# cookies are host-scoped, so the sessions never mix.
#
# Sub-path serving is upstream's X-Forwarded-Prefix contract
# (hermes_cli/web_server.py mount_spa, dashboard_auth/prefix.py): nginx
# strips the prefix off the upstream URI and names it in the header;
# hermes rewrites the SPA's absolute asset URLs, sets __HERMES_BASE_PATH__
# and scopes the session cookies to Path=/<user>. The legacy host sends no
# prefix, so its cookies sit at Path=/ - the two never collide.
# HERMES_DASHBOARD_PUBLIC_URL is only the OAuth redirect_uri authority
# (dashboard_auth/routes.py); the password provider never reads it, so
# the canonical URL is fine for both hosts.
#
# One upstream gap: the password login page (dashboard_auth/login_page.py,
# _PASSWORD_FORM_SCRIPT) is hand-written HTML, not the SPA, and its inline
# script POSTs to the absolute `/auth/password-login` and lands on
# `data.next || '/'` - both blind to the prefix, so from /<user>/login
# they hit this vhost's root and 404. Until upstream threads the prefix
# through, the prefixed location patches those two literals with
# sub_filter (text/html only, one hit each; the SPA's index carries
# neither string). `next` is only prefixed when relative: for the desktop
# app's RFC 8252 sign-in (routes.py auth_password_login, native branch) it
# is the app's absolute http://127.0.0.1:<port>/callback and must pass
# through untouched. sub_filter needs an uncompressed upstream body, hence
# the blank Accept-Encoding; TLS-side compression is unaffected.
#
# Second upstream gap: the SPA is a Vite build with base `/`, so its
# lazy route chunks (ChatPage, xterm, ...) are loaded by the preload
# helper from the root-absolute `/assets/<name>-<hash>.<ext>`, not from
# `import.meta.url`; mount_spa only rewrites index.html and CSS, never
# the JS. Every route past the entry point therefore rendered blank. The
# shared vhost serves `/assets/` from one backend: assets are unauthed,
# content-hashed and identical across users (one hermes package per
# host), so any native user's backend answers for all of them.
#
# Why the dashboard unit is re-scripted: spaces' native.nix binds the
# dashboard to 127.0.0.1, and hermes treats a loopback bind as "trusted
# operator": no login, a static session token injected into the SPA
# (hermes_cli/web_server.py should_require_auth). Behind a public proxy
# that is an open control plane. Any NON-loopback bind engages hermes'
# auth gate, which then needs an auth provider: the bundled
# plugins/dashboard_auth/basic password provider, configured through
# HERMES_DASHBOARD_BASIC_AUTH_* env vars. So the unit binds `0.0.0.0`
# (accepts any Host header, which also lets the browser Origin of either
# public host pass the WebSocket guard) and exports the credentials from
# systemd credentials. Those env names exceed spaces' 28-char secretEnv
# limit, so they ride the dashboard unit's own LoadCredential instead.
#
# Not `::`: asyncio sets IPV6_V6ONLY on an explicit v6 bind, so 127.0.0.1
# (nginx and the root-held forward) would get RST.
#
# Reach of the `0.0.0.0` bind: the NixOS firewall keeps the backend port
# closed to the outside, and the login gate covers everything else.
# spaces' owner-only iptables rule on that port (hermes/firewall.nix)
# still rejects every local uid but the owner and root, so nginx gets its
# own RETURN rule ahead of it. The root-held forward at
# users.<user>.dashboardPort and `hermes-desktop` keep working; the
# desktop logs in through the cookie flow.
#
# Secrets (per-machine generator per user, no prompts):
#   clan vars generate <machine> --generator hermes-dashboard-<user>
#   clan vars get <machine> hermes-dashboard-<user>/password  # give to the user
# password: random diceware passphrase; password_hash: scrypt in the
# plugin's own format (scrypt$n$r$p$salt$dk, n=2^14 r=8 p=1 dklen=32);
# secret: session-token HMAC key, fixed so logins survive restarts.
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.hermesDashboard;
  portOf = user: 20000 + config.users.users.${user}.uid;
  unitOf = user: "hermes-dashboard-${user}";
  genOf = user: config.clan.core.vars.generators."hermes-dashboard-${user}";

  proxyLocation = user: prefix: {
    proxyPass = "http://127.0.0.1:${toString (portOf user)}/";
    # /api/ws and /api/pty are long-lived websockets; the PTY stream
    # and SSE status feeds sit idle for far longer than nginx's 60s.
    proxyWebsockets = true;
    extraConfig = ''
      ${lib.optionalString (prefix != "") ''
        proxy_set_header X-Forwarded-Prefix ${prefix};
        proxy_set_header Accept-Encoding "";
        sub_filter "fetch('/auth/password-login'" "fetch('${prefix}/auth/password-login'";
        sub_filter "window.location.assign((data && data.next) || '/')" "window.location.assign((function (n) { return /^https?:\\/\\//.test(n) ? n : '${prefix}' + n; })((data && data.next) || '/'))";
      ''}
      proxy_read_timeout 1h;
      proxy_send_timeout 1h;
      client_max_body_size 256m;
    '';
  };

  # Locations of a vhost that carries every user under `base`/<user>/
  # (base "" or "/hermes"). Nothing at the root: the user list is not
  # public. nginx answers `base`/<user> with a 301 to `base`/<user>/ on its
  # own (prefix location with trailing slash + proxy_pass). `/assets/`:
  # see the header; the URI passes through unchanged (no trailing slash
  # on proxy_pass).
  userLocations = base: {
    "/".return = "404";
    "/assets/".proxyPass = "http://127.0.0.1:${toString (portOf (lib.head (lib.attrNames cfg.users)))}";
  }
  // lib.mapAttrs' (
    user: _: lib.nameValuePair "${base}/${user}/" (proxyLocation user "${base}/${user}")
  ) cfg.users;

  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.users);
  legacyUsers = lib.filterAttrs (_: u: u.legacyHost != null) cfg.users;
in
{
  options.hyper.hermesDashboard = {
    host = lib.mkOption {
      type = lib.types.str;
      description = "Shared public hostname; each user's dashboard lives at https://<host>/<user>/.";
    };
    internalHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${config.networking.hostName}.${config.clan.core.settings.domain}";
      defaultText = "<hostName>.<clan domain>";
      description = "Clan-internal hostname serving http://<internalHost>/hermes/<user>/ without TLS; null disables.";
    };
    users = lib.mkOption {
      default = { };
      description = "Native hermes users whose dashboard is published.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.legacyHost = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Older dedicated hostname still serving this dashboard at its root.";
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.users != { }) {
    assertions = lib.mapAttrsToList (user: _: {
      assertion = config.services.hermes-microvm.users.${user}.native or false;
      message = "hyper.hermesDashboard.users.${user}: only a native hermes user has a host dashboard unit to publish.";
    }) cfg.users;

    clan.core.vars.generators = forEachUser (
      user: _: {
        "hermes-dashboard-${user}" = {
          runtimeInputs = [
            pkgs.diceware
            (pkgs.python3.withPackages (_: [ ]))
          ];
          # The plaintext is for `clan vars get`; only the hash reaches the host.
          files.password.deploy = false;
          files.password_hash.restartUnits = [ "${unitOf user}.service" ];
          files.secret.restartUnits = [ "${unitOf user}.service" ];
          script = ''
            diceware -n 6 -d - --no-caps > "$out"/password
            python3 - "$out" <<'PY'
            import base64, hashlib, secrets, sys
            out = sys.argv[1]
            pw = open(f"{out}/password").read().strip()
            salt = secrets.token_bytes(16)
            dk = hashlib.scrypt(pw.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32, maxmem=0)
            b64 = lambda b: base64.b64encode(b).decode()
            open(f"{out}/password_hash", "w").write(f"scrypt$16384$8$1''${b64(salt)}''${b64(dk)}")
            open(f"{out}/secret", "w").write(secrets.token_urlsafe(48))
            PY
          '';
        };
      }
    );

    systemd.services = lib.mkMerge [
      (forEachUser (
        user: _: {
          ${unitOf user} = {
            environment = {
              HERMES_DASHBOARD_BASIC_AUTH_USERNAME = user;
              HERMES_DASHBOARD_PUBLIC_URL = "https://${cfg.host}/${user}";
            };
            serviceConfig.LoadCredential = [
              "basic_auth_password_hash:${(genOf user).files.password_hash.path}"
              "basic_auth_secret:${(genOf user).files.secret.path}"
            ];
            # Replaces spaces native.nix's script: same session env (its
            # hermes-native-session-env wrapper), same token, plus the two
            # credential exports and `--host 0.0.0.0`. The hermes package
            # itself is a let-binding there, not an option; it is on this
            # unit's `path` after the user's venv root, so pick the store
            # entry by name rather than trusting whatever the venv grew.
            # Re-check against native.nix on a spaces bump.
            script = lib.mkForce ''
              uid=$(id -u)
              export XDG_RUNTIME_DIR="/run/user/$uid"
              export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus"
              HERMES_DASHBOARD_SESSION_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/dashboard_token")
              HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$(cat "$CREDENTIALS_DIRECTORY/basic_auth_password_hash")
              HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(cat "$CREDENTIALS_DIRECTORY/basic_auth_secret")
              export HERMES_DASHBOARD_SESSION_TOKEN HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH HERMES_DASHBOARD_BASIC_AUTH_SECRET
              hermes=
              IFS=: ; for d in $PATH; do
                case "$d" in /nix/store/*-hermes-agent-*/bin) hermes="$d/hermes"; break ;; esac
              done
              unset IFS
              [ -x "$hermes" ] || { echo "no hermes-agent package on PATH" >&2; exit 1; }
              exec "$hermes" dashboard --no-open --host 0.0.0.0 --port ${toString (portOf user)}
            '';
          };
        }
      ))
      {
        # nginx may dial the owner-gated backend ports. -I puts them before
        # the REJECT spaces appends for each port.
        hermes-firewall.script = lib.mkAfter (
          lib.concatMapStrings (user: ''
            iptables -w -I hermes-microvm 1 -p tcp --dport ${toString (portOf user)} -m owner --uid-owner nginx -j RETURN
          '') (lib.attrNames cfg.users)
        );
      }
    ];

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
    security.acme = {
      acceptTerms = true;
      defaults.email = "info@davhau.com";
    };
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts = lib.mkMerge [
        {
          ${cfg.host} = {
            forceSSL = true;
            enableACME = true;
            locations = userLocations "";
          };
        }
        (lib.mkIf (cfg.internalHost != null) {
          ${cfg.internalHost}.locations = userLocations "/hermes";
        })
        (lib.mapAttrs' (
          user: u:
          lib.nameValuePair u.legacyHost {
            forceSSL = true;
            enableACME = true;
            locations."/" = proxyLocation user "";
          }
        ) legacyUsers)
      ];
    };
  };
}
