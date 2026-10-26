# The agents' browser: per agent a camofox-browser server driving a
# headful Camoufox (anti-detect Firefox over Juggler, no CDP), behind
# hermes' built-in browser_* tools (its Camofox backend,
# tools/browser_camofox.py). With Camofox selected, hermes drops the
# CDP-only browser_exec tool (tools/browser_use_cli.py,
# is_browser_use_cli_mode).
#
# Per agent, as the agent's uid:
#   - the server binds 127.0.0.1:<camofoxBackendBase + uid>; the agent
#     dials its root-held port (hyperhermes.lib), bridged per connection
#     by core's owner-checking forward (services.hyperhermes.forwards),
#     which also starts the server on first use; both ports are owner-only
#     (core's firewall),
#   - every route but /health needs the agent's access key, generated
#     once into a 0600 file in the agent's 0700 state dir,
#   - the profile store (cookies and storage of hermes' stable per-agent
#     userId, so a cleared Cloudflare or Akamai check carries over) lives
#     next to it,
#   - Camoufox draws on an Xvfb that camofox-browser starts with the
#     browser and kills with it (5 idle minutes), so the display costs
#     memory only while the agent browses. Its socket lives only in the
#     unit's private /tmp; the abstract socket is off (pkgs/camofox-browser).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  hlib = inputs.hyperhermes.lib;

  # The default build (pkgs/camoufox/browser.nix), as web-extract uses.
  # camofox-browser 1.18.1 downloads 152.0.4-beta.30 for itself
  # (lib/camoufox-download.js), but its camoufox-js 0.11.5 runs 156 as
  # well, and 152 can drop a humanized mouse event on the content's top
  # row and then hold every later mouse event of the browser behind it
  # (Camoufox #751/#752, fixed in 156.0.1-beta.36).
  camoufox = pkgs.callPackage ../../../pkgs/camoufox/browser.nix { };
  camofox = pkgs.callPackage ../../../pkgs/camofox-browser { };

  # Seconds a navigation waits for a challenge interstitial to clear,
  # ticking Cloudflare's Turnstile box when it draws one; non-zero also
  # launches Camoufox with disable_coop so that click reaches the frame
  # (pkgs/camofox-browser/challenge-wait.patch).
  challengeWait = 30;
  # A navigation route's budget is NAVIGATE_TIMEOUT_MS + the challenge
  # wait + 5 s (patch); hermes gives a navigate 60 s
  # (browser_camofox.py, _navigate_tab).
  navigateTimeout = 20;

  keyFile = user: "${hlib.camofoxDir user}/access-key";

  # Both the server and the agent run this before they read the key, in
  # either order: the first link wins, the loser's copy is dropped.
  ensureKey =
    user:
    pkgs.writeShellScript "hermes-camofox-key" ''
      set -eu
      umask 0077
      key=${keyFile user}
      [ -s "$key" ] && exit 0
      ${pkgs.coreutils}/bin/mkdir -p ${hlib.camofoxDir user}
      ${pkgs.coreutils}/bin/od -An -N32 -tx1 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n' > "$key.$$"
      ${pkgs.coreutils}/bin/ln "$key.$$" "$key" 2>/dev/null || true
      ${pkgs.coreutils}/bin/rm -f "$key.$$"
    '';

  serve =
    user:
    pkgs.writeShellScript "hermes-camofox" ''
      set -eu
      CAMOFOX_ACCESS_KEY=$(${pkgs.coreutils}/bin/cat ${keyFile user})
      CAMOFOX_PORT=$((${toString hlib.camofoxBackendBase} + $(${pkgs.coreutils}/bin/id -u)))
      export CAMOFOX_ACCESS_KEY CAMOFOX_PORT
      exec ${lib.getExe camofox}
    '';

  # The unit counts as started once the server listens, so the first
  # forwarded connection does not race the bind.
  awaitListen = pkgs.writeShellScript "hermes-camofox-ready" ''
    port=$((${toString hlib.camofoxBackendBase} + $(${pkgs.coreutils}/bin/id -u)))
    for _ in $(${pkgs.coreutils}/bin/seq 100); do
      (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && exit 0
      ${pkgs.coreutils}/bin/sleep 0.2
    done
    exit 1
  '';

  forEachUser = f: lib.mkMerge (lib.mapAttrsToList (user: _: f user) cfg.agents);
in
{
  config = lib.mkIf cfg.browser.enable {
    services.hyperhermes.forwards.camofox = {
      label = "Camofox";
      portFor = hlib.camofoxPortFor;
      backendBase = hlib.camofoxBackendBase;
    };

    services.hyperhermes.settings.browser = {
      cloud_provider = lib.mkDefault "camofox";
      # A stable per-agent userId: Camofox keeps that profile's cookies.
      camofox.managed_persistence = lib.mkDefault true;
      # Tab creation, which carries the first navigation, may take its
      # route budget (60 s with the challenge wait) before it answers.
      command_timeout = lib.mkDefault 65;
    };

    systemd.services = forEachUser (
      user:
      let
        dir = hlib.camofoxDir user;
      in
      {
        "hermes-camofox-${user}" = {
          description = "Camofox browser server of hermes agent ${user}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          unitConfig.RequiresMountsFor = [ (hlib.stateDir user) ];
          environment = {
            HOME = dir;
            NODE_ENV = "production";
            CAMOFOX_BIND_HOST = "127.0.0.1";
            CAMOUFOX_EXECUTABLE = "${camoufox}/lib/camoufox/camoufox";
            # Otherwise uBlock is downloaded at every browser launch.
            CAMOFOX_DISABLE_DEFAULT_ADDONS = "1";
            CAMOFOX_PROFILE_DIR = "${dir}/profiles";
            CAMOFOX_CHALLENGE_WAIT_MS = toString (challengeWait * 1000);
            NAVIGATE_TIMEOUT_MS = toString (navigateTimeout * 1000);
            # One agent: its persistent userId, plus the odd ephemeral one.
            MAX_SESSIONS = "2";
            MAX_TABS_PER_SESSION = "4";
            MAX_TABS_GLOBAL = "6";
            # Firefox closes after 5 idle minutes; the server stays.
            BROWSER_IDLE_TIMEOUT_MS = "300000";
            BROWSER_RSS_RESTART_THRESHOLD_MB = "1200";
          }
          # hermes' browser_solve_captcha: the captcha plugin
          # (pkgs/camofox-browser) runs CaptchaKraken's engine, which reads
          # each challenge with this model.
          // lib.optionalAttrs (cfg.browser.captchaSolver.baseUrl != null) {
            VLLM_BASE_URL = cfg.browser.captchaSolver.baseUrl;
            CAPTCHA_LORA_NAME = cfg.browser.captchaSolver.model;
          };
          # Xvfb for the headful browser; camoufox-js finds it with `which`.
          path = [
            pkgs.xvfb
            pkgs.which
          ];
          serviceConfig = {
            User = user;
            Group = "users";
            UMask = "0077";
            ExecStartPre = ensureKey user;
            ExecStart = serve user;
            ExecStartPost = awaitListen;
            # SIGTERM to the server only: it saves the profile's cookies
            # from the live browser, then closes it. Signalled together,
            # Firefox would be gone before the save.
            KillMode = "mixed";
            Restart = "on-failure";
            RestartSec = 5;
            MemoryMax = "1536M";
            TasksMax = 1024;
            CPUQuota = "200%";
            # Holds the Xvfb socket: other uids cannot reach the display.
            # Also where the server keeps downloads (os.tmpdir(), for
            # hermes' browser_downloads): the last 20 per tab, deleted
            # with their tab or session, and all of them when the unit
            # stops. A tmpfs /tmp would count them against MemoryMax.
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [ dir ];
            NoNewPrivileges = true;
          };
        };

        # Started by the first connection to the agent's root-held port.
        "hermes-camofox-fwd-${user}@" = {
          wants = [ "hermes-camofox-${user}.service" ];
          after = [ "hermes-camofox-${user}.service" ];
        };

        # The key rides the agent's .env (CAMOFOX_API_KEY is what hermes
        # sends as its Bearer token); the managed .env is world-readable.
        "hermes-agent-${user}".preStart = lib.mkAfter ''
          ${ensureKey user}
          env_file=${hlib.stateDir user}/.hermes/.env
          ${pkgs.gnused}/bin/sed -i \
            '/^# BEGIN hermes-native camofox$/,/^# END hermes-native camofox$/d' "$env_file"
          {
            echo "# BEGIN hermes-native camofox"
            echo "CAMOFOX_URL=http://127.0.0.1:${toString (hlib.camofoxPortFor user)}"
            echo "CAMOFOX_API_KEY=$(${pkgs.coreutils}/bin/cat ${keyFile user})"
            echo "# END hermes-native camofox"
          } >> "$env_file"
        '';
      }
    );

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      user: _: "d ${hlib.camofoxDir user} 0700 ${user} users - -"
    ) cfg.agents;
  };
}
