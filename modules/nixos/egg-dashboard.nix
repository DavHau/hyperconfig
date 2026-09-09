# egg's hermes web dashboard on the public internet: https://egg.davhau.com
# (AAAA -> som's stable public v6, networking.publicIPv6Token) -> nginx
# (ACME) -> the native dashboard backend on 127.0.0.1:20000+uid.
#
# Why the dashboard unit is re-scripted: spaces' native.nix binds the
# dashboard to 127.0.0.1, and hermes treats a loopback bind as "trusted
# operator": no login, a static session token injected into the SPA
# (hermes_cli/web_server.py should_require_auth). Behind a public proxy
# that is an open control plane. Any NON-loopback bind engages hermes'
# auth gate, which then needs an auth provider: the bundled
# plugins/dashboard_auth/basic password provider, configured through
# HERMES_DASHBOARD_BASIC_AUTH_* env vars. So the unit binds `0.0.0.0`
# (accepts any Host header, which also lets the browser Origin
# egg.davhau.com pass the WebSocket guard) and exports the credentials
# from systemd
# credentials. Those env names exceed spaces' 28-char secretEnv limit, so
# they ride the dashboard unit's own LoadCredential instead.
#
# Not `::`: asyncio sets IPV6_V6ONLY on an explicit v6 bind, so 127.0.0.1
# (nginx and the root-held forward) would get RST.
#
# Reach of the `0.0.0.0` bind: the NixOS firewall keeps :21004 closed to the
# outside, and the login gate covers everything else. spaces' owner-only
# iptables rule on that port (hermes/firewall.nix) still rejects every
# local uid but egg and root, so nginx gets its own RETURN rule ahead of it.
# The root-held forward at users.egg.dashboardPort and `hermes-desktop`
# keep working; the desktop now logs in through the cookie flow.
#
# Secrets (per-machine generator, no prompts):
#   clan vars generate som --generator hermes-dashboard-egg
#   clan vars get som hermes-dashboard-egg/password    # give this to egg
# password: random diceware passphrase; password_hash: scrypt in the
# plugin's own format (scrypt$n$r$p$salt$dk, n=2^14 r=8 p=1 dklen=32);
# secret: session-token HMAC key, fixed so logins survive restarts.
{ config, lib, pkgs, ... }:
let
  user = "egg";
  host = "egg.davhau.com";
  port = 20000 + config.users.users.${user}.uid;
  gen = config.clan.core.vars.generators."hermes-dashboard-${user}";
  unit = "hermes-dashboard-${user}";
in
{
  clan.core.vars.generators."hermes-dashboard-${user}" = {
    runtimeInputs = [
      pkgs.diceware
      (pkgs.python3.withPackages (_: [ ]))
    ];
    # The plaintext is for `clan vars get`; only the hash reaches som.
    files.password.deploy = false;
    files.password_hash.restartUnits = [ "${unit}.service" ];
    files.secret.restartUnits = [ "${unit}.service" ];
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

  systemd.services.${unit} = {
    environment = {
      HERMES_DASHBOARD_BASIC_AUTH_USERNAME = user;
      # Authority for cookie flags and redirects behind the TLS terminator.
      HERMES_DASHBOARD_PUBLIC_URL = "https://${host}";
    };
    serviceConfig.LoadCredential = [
      "basic_auth_password_hash:${gen.files.password_hash.path}"
      "basic_auth_secret:${gen.files.secret.path}"
    ];
    # Replaces spaces native.nix's script: same session env (its
    # hermes-native-session-env wrapper), same token, plus the two
    # credential exports and `--host 0.0.0.0`. The hermes package itself is a
    # let-binding there, not an option; it is on this unit's `path` after
    # the user's venv root, so pick the store entry by name rather than
    # trusting whatever the venv grew. Re-check against native.nix on a
    # spaces bump.
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
      exec "$hermes" dashboard --no-open --host 0.0.0.0 --port ${toString port}
    '';
  };

  # nginx may dial the owner-gated backend port. -I puts it before the
  # REJECT spaces appends for that port.
  systemd.services.hermes-firewall.script = lib.mkAfter ''
    iptables -w -I hermes-microvm 1 -p tcp --dport ${toString port} -m owner --uid-owner nginx -j RETURN
  '';

  networking.firewall.allowedTCPPorts = [ 80 443 ];
  security.acme = {
    acceptTerms = true;
    defaults.email = "info@davhau.com";
  };
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts.${host} = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        # /api/ws and /api/pty are long-lived websockets; the PTY stream
        # and SSE status feeds sit idle for far longer than nginx's 60s.
        proxyWebsockets = true;
        extraConfig = ''
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
          client_max_body_size 256m;
        '';
      };
    };
  };
}
