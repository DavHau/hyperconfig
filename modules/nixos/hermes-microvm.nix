# Hermes Agent (NousResearch) in per-user MicroVMs — microvm.nix, fully
# declarative, qemu + slirp user networking (no host bridge/NAT; coexists
# with NetworkManager).
#
# One VM per configured user ("hermes-<user>"). Inside each guest the
# UPSTREAM hermes NixOS module runs in native mode as a guest account with
# the same name/uid as the host user, so the virtiofs-shared home keeps
# consistent ownership. The guest gets the host's /nix/store read-only, a
# private ext4 volume for HERMES state (sqlite WAL stays off virtiofs), the
# owner's home read-write, and passwordless sudo (parity with the old
# container's self-modification support).
#
# Host <-> guest interfaces (per user, all on 127.0.0.1):
#   - `hermes` CLI/TUI: host shim ssh-execs into the owner's VM with a
#     dedicated per-user keypair (0600, owner-only) — same seam as the old
#     docker-exec routing. State never crosses the VM boundary, so the
#     gateway/CLI sqlite+lockfile coordination stays inside one kernel.
#   - Web dashboard: guest `hermes dashboard` on 127.0.0.1:9118 in loopback
#     mode (upstream's non-loopback auth gate is cookie-only — no static
#     token contract), bridged by a guest socat to the NIC-facing 9119
#     slirp forward, then to host 127.0.0.1:<dashboardPort>. Auth: a fixed
#     per-user HERMES_DASHBOARD_SESSION_TOKEN generated on the host; the
#     real boundary is the iptables owner match on the forwarded port.
#   - Hermes Desktop: host `hermes-desktop` wrapper launches the upstream
#     Electron app against the owner's forwarded dashboard via
#     HERMES_DESKTOP_REMOTE_URL/_TOKEN (token file 0400 owner-only).
#   - spaces MCP: guest socat -> slirp host alias 10.0.2.2:<spacesPort> ->
#     host socat (running as the owner) -> the per-user gateway socket in
#     /run/user/<uid>.
#   - clipboard (per-user opt-in `clipboard.enable`): hermes image paste
#     shells out to wl-paste, which cannot work in a headless guest. A
#     guest wl-paste shim forwards two whitelisted read-only requests via
#     slirp to a host socat (running as the owner) that runs the real
#     wl-paste against the session compositor. The WAYLAND_DISPLAY gate in
#     hermes/the TUI is satisfied by the host value the `hermes` shim
#     forwards over ssh.
#
# Isolation between users: ssh keys and dashboard tokens are owner-only
# files, and iptables OUTPUT owner-match rules reject other local users on
# every forwarded loopback port. Residual caveats:
#   - all VMs' qemu processes run as the shared `microvm` user, so one
#     user's *guest* could reach another user's spaces bridge port (and
#     host loopback services like the simplex daemon);
#   - owner-match gates CONNECTS, not LISTENS: while a VM is down, any
#     local user can squat its free forwarded port. ssh fails closed
#     (pinned host key); the shim/desktop wrappers refuse to talk unless
#     the VM unit is active, but a browser can still be phished into
#     sending the dashboard token to a squatter. Full fix would be a
#     vsock backend behind a root-held socket;
#   - the guest is trusted with the owner's HOST account: rw home means a
#     hostile agent can plant dotfiles that run at the next interactive
#     login — and where the owner is a nix trusted-user, that is
#     root-equivalent. Deliberate (container parity), but know it.
# All acceptable for now with a single configured user.
#
# pip: guests get a venv at /var/lib/hermes/.venv created from a nixpkgs
# python-with-packages interpreter with --system-site-packages, so the
# preinstalled scientific stack is importable AND `pip install` works
# (writable venv; wheel shared-lib deps resolve via LD_LIBRARY_PATH below
# — nix-ld only covers pip-installed *executables*, not extension modules
# dlopen'd by the nix-built interpreter).
#
# Hardware acceleration: the iGPU cannot be passed through (the host
# desktop owns it), so computation acceleration is CPU-side: openblas-
# backed numpy/scipy, CPU torch with AVX-512, numba JIT.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.hermes-microvm;

  vmName = user: "hermes-${user}";
  baseDir = user: "/var/lib/hermes-microvm/${user}";

  # Fixed guest paths
  guestStateDir = "/var/lib/hermes";
  guestHostDir = "/run/hermes-host"; # ro virtiofs: ssh keys + secrets
  guestVenv = "${guestStateDir}/.venv";
  guestWorkspace = "${guestStateDir}/workspace";
  # NIC-facing port the slirp forward targets (guest socat listens here)
  dashboardGuestPort = 9119;
  # loopback bind of `hermes dashboard` behind the socat bridge
  dashboardGuestBackendPort = 9118;
  # slirp's alias for the host's loopback
  slirpHostAlias = "10.0.2.2";

  # Locally-administered unicast MAC derived from the uid (unique per VM).
  macFor = uid:
    let h = lib.toLower (lib.fixedWidthString 4 "0" (lib.toHexString uid));
    in "02:00:00:00:${builtins.substring 0 2 h}:${builtins.substring 2 2 h}";

  pythonEnv = pkgs.python3.withPackages cfg.pythonPackages;

  # Tools the agent sees on PATH (service, ssh shells, cron, skills).
  baseGuestPackages = with pkgs; [
    # vcs / basics
    git curl wget jq ripgrep fd file unzip zip gnutar xz
    # build toolchain so pip can compile the odd sdist; binutils also
    # provides the `ld` that ctypes.util.find_library needs
    gcc gnumake pkg-config binutils
    # documents / media / research helpers
    pandoc poppler-utils ffmpeg imagemagick sqlite yt-dlp w3m
    # runtimes & package managers agents reach for
    nodejs uv
  ];

  # Shared libs for `pip install`ed manylinux wheels. Served two ways:
  # nix-ld (standalone executables whose ELF interpreter is
  # /lib64/ld-linux) and LD_LIBRARY_PATH (extension modules dlopen'd by
  # the nix-built venv python, which nix-ld never sees).
  nixLdLibraries = with pkgs; [
    stdenv.cc.cc
    zlib
    zstd
    openssl
    curl
    expat
    libxml2
    libxslt
    libffi
    bzip2
    ncurses
    fontconfig
    freetype
  ];
  wheelLibraryPath = lib.makeLibraryPath nixLdLibraries;

  # Guest-side `wl-paste` for the clipboard bridge: hermes image paste
  # (hermes_cli/clipboard.py) and the TUI's text-clipboard read both shell
  # out to wl-paste, so a shim with the same CLI surface is the whole guest
  # integration. Protocol: one request line ("list-types" | "type <mime>"),
  # response = wl-paste's exit code on the first line + the raw payload.
  clipboardShimFor = ucfg: pkgs.writeShellScriptBin "wl-paste" ''
    set -eu
    case "''${1:-}" in
      --list-types|-l) req="list-types" ;;
      --type|-t) req="type ''${2:?wl-paste: --type needs an argument}" ;;
      *)
        echo "wl-paste (hermes clipboard bridge): unsupported arguments: $*" >&2
        exit 1
        ;;
    esac
    exec 3<>/dev/tcp/${slirpHostAlias}/${toString ucfg.clipboardPort}
    printf '%s\n' "$req" >&3
    IFS= read -r rc <&3
    cat <&3
    case "$rc" in "" | *[!0-9]*) exit 1 ;; esac
    exit "$rc"
  '';

  # Host side of the clipboard bridge (one process per connection, spawned
  # by the socat listener as the owning user). The request line is never
  # passed through verbatim: wl-paste has argument forms that execute
  # commands (--watch), so only the two read-only invocations the guest
  # shim emits are allowed.
  clipboardServer = user: ucfg: pkgs.writeShellScript "hermes-clipboard-server-${user}" ''
    set -eu
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils gnugrep wl-clipboard ])}
    export XDG_RUNTIME_DIR=/run/user/${toString ucfg.uid}
    # System service, no session env: find the compositor socket ourselves.
    # No graphical session -> wl-paste fails -> rc=1 reaches the guest,
    # which reports the ordinary "No image found in clipboard".
    if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      for s in "$XDG_RUNTIME_DIR"/wayland-*; do
        [ -S "$s" ] || continue
        WAYLAND_DISPLAY="''${s##*/}"
        export WAYLAND_DISPLAY
        break
      done
    fi
    reply() {
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      rc=0
      timeout 10 wl-paste "$@" > "$tmp" 2>/dev/null || rc=$?
      printf '%s\n' "$rc"
      cat "$tmp"
    }
    IFS= read -r req || exit 0
    case "$req" in
      list-types)
        reply --list-types
        ;;
      "type "*)
        mime="''${req#type }"
        if printf '%s' "$mime" | grep -Eq '^[A-Za-z][A-Za-z0-9/.+-]*$'; then
          reply --type "$mime"
        else
          printf '1\n'
        fi
        ;;
      *)
        printf '1\n'
        ;;
    esac
  '';

  # Root ExecStartPre of microvm@hermes-<user>: per-user keys, dashboard
  # credentials, guest secret env files, VM state dir lockdown, and a
  # bounded wait for the owner's spaces gateway socket.
  provisionScript = user: ucfg: pkgs.writeShellScript "hermes-microvm-provision-${user}" ''
    set -eu
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils gawk openssh openssl ])}
    base=${baseDir user}
    # dirs come from the tmpfiles rules (virtiofsd needs them before this
    # script ever runs); everything below is secret material that cannot
    # live in the world-readable nix store, so it is generated here.

    # ssh client key: the owner's credential for `hermes` CLI routing
    if [ ! -f "$base/ssh/client_ed25519" ]; then
      ssh-keygen -q -t ed25519 -N "" -C "hermes-microvm-${user}" -f "$base/ssh/client_ed25519"
    fi
    chown ${user} "$base/ssh/client_ed25519"
    chmod 0600 "$base/ssh/client_ed25519"

    # guest ssh host key (stable across guest rebuilds) + authorized key
    if [ ! -f "$base/guest/ssh/ssh_host_ed25519_key" ]; then
      ssh-keygen -q -t ed25519 -N "" -C "${vmName user}" -f "$base/guest/ssh/ssh_host_ed25519_key"
    fi
    chmod 0600 "$base/guest/ssh/ssh_host_ed25519_key"
    chmod 0644 "$base/guest/ssh/ssh_host_ed25519_key.pub"
    install -m 0644 "$base/ssh/client_ed25519.pub" "$base/guest/ssh/authorized_keys"
    awk -v port=${toString ucfg.sshPort} '{ print "[127.0.0.1]:" port " " $1 " " $2 }' \
      "$base/guest/ssh/ssh_host_ed25519_key.pub" > "$base/ssh/known_hosts"
    chmod 0644 "$base/ssh/known_hosts"

    # dashboard session token: fixed HERMES_DASHBOARD_SESSION_TOKEN for the
    # loopback-mode dashboard; owner-readable (0400) copy so the
    # hermes-desktop wrapper can pass it as HERMES_DESKTOP_REMOTE_TOKEN.
    if [ ! -f "$base/desktop-token" ]; then
      (umask 277; openssl rand -hex 32 | tr -d '\n' > "$base/desktop-token")
    fi
    chown ${user} "$base/desktop-token"
    chmod 0400 "$base/desktop-token"

    # secrets handed to the guest (root-only inside the ro mount)
    umask 077
    {
      printf 'HERMES_DASHBOARD_SESSION_TOKEN=%s\n' "$(cat "$base/desktop-token")"
    } > "$base/guest/secrets/dashboard.env"
    : > "$base/guest/secrets/hermes.env.tmp"
    ${lib.concatMapStrings (f: ''
      cat ${f} >> "$base/guest/secrets/hermes.env.tmp" 2>/dev/null \
        && printf '\n' >> "$base/guest/secrets/hermes.env.tmp" \
        || echo "hermes-microvm: missing environment file ${f}" >&2
    '') ucfg.environmentFiles}
    mv "$base/guest/secrets/hermes.env.tmp" "$base/guest/secrets/hermes.env"

    # VM state dir holds the hermes state volume image — no world access
    if [ -d /var/lib/microvms/${vmName user} ]; then
      chmod 0750 /var/lib/microvms/${vmName user}
    fi

    # Seed the guest timezone mirror before boot (kept fresh afterwards by
    # the hermes-microvm-timezone path unit).
    ${tzSyncScript}

    ${lib.optionalString ucfg.spacesGateway.enable ''
      # Bounded wait for the owner's spaces gateway socket (linger brings
      # the user manager up at boot). Non-fatal: MCP reconnects later.
      for _i in $(seq 1 60); do
        [ -S ${ucfg.spacesGateway.socket} ] && break
        sleep 1
      done
    ''}
  '';

  # Mirror the host's /etc/localtime (deref'd TZif bytes, atomic replace)
  # into every user's shared guest dir. A pure mount can't do this: the
  # host timezone is a symlink in /etc (virtiofs shares directories only,
  # and sharing /etc would leak secrets). Runs at provisioning and on every
  # /etc/localtime swap (timedatectl, automatic-timezoned, rebuild).
  tzSyncScript = pkgs.writeShellScript "hermes-microvm-tz-sync" ''
    set -eu
    # Own the umask: the provisioning script calls this after `umask 077`,
    # which once produced an untraversable 0700 tz dir (guest fell back to
    # UTC). chmod repairs dirs created by that bug.
    umask 022
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    src=/etc/localtime
    [ -e "$src" ] || src=${pkgs.tzdata}/share/zoneinfo/UTC
    ${lib.concatMapStrings (u: ''
      d=${baseDir u}/guest/tz
      mkdir -p "$d"
      chmod 0755 "$d"
      cp -Lf "$src" "$d/.localtime.tmp"
      chmod 0644 "$d/.localtime.tmp"
      mv "$d/.localtime.tmp" "$d/localtime"
    '') (lib.attrNames cfg.users)}
  '';

  # ── Guest NixOS configuration (fully declarative microvm) ────────────
  guestConfig = user: ucfg: { config, lib, pkgs, ... }: {
    imports = [ inputs.hermes-agent.nixosModules.default ];

    networking.hostName = vmName user;
    system.stateVersion = "26.05";

    microvm = {
      hypervisor = "qemu";
      vcpu = cfg.vcpu;
      mem = cfg.mem;
      # slirp user networking: outbound internet with zero host network
      # setup; inbound only through the explicit forwards below.
      interfaces = [
        {
          type = "user";
          id = "hermes";
          mac = macFor ucfg.uid;
        }
      ];
      forwardPorts = [
        {
          from = "host";
          proto = "tcp";
          host.address = "127.0.0.1";
          host.port = ucfg.sshPort;
          guest.port = 22;
        }
        {
          from = "host";
          proto = "tcp";
          host.address = "127.0.0.1";
          host.port = ucfg.dashboardPort;
          guest.port = dashboardGuestPort;
        }
      ];
      shares = [
        {
          proto = "virtiofs";
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
        }
        {
          proto = "virtiofs";
          tag = "home";
          source = "/home/${user}";
          mountPoint = "/home/${user}";
        }
        {
          proto = "virtiofs";
          tag = "host-config";
          source = "${baseDir user}/guest";
          mountPoint = guestHostDir;
          readOnly = true;
        }
      ];
      # Private ext4 volume for HERMES state: keeps the gateway's sqlite
      # WAL + flock coordination on a real local fs, persists across guest
      # rebuilds, and lives under /var/lib/microvms/<vm> (0750) on the host.
      volumes = [
        {
          image = "hermes-state.img";
          mountPoint = guestStateDir;
          size = cfg.stateSize;
        }
      ];
      # Writable store overlay so `nix` works inside the guest.
      writableStoreOverlay = "/nix/.rw-store";
    };

    # Guest-visible microvm.optimize defaults, pinned explicitly (mirrors
    # microvm.nix nixos-modules/microvm/optimization.nix; one deliberate
    # divergence: upstream keeps system.switch enabled when sshd + a store
    # share make switching viable — these guests are fully declarative, so
    # it stays off).
    documentation.enable = lib.mkDefault false;
    boot.initrd.systemd.enable = lib.mkDefault true;
    boot.initrd.systemd.tpm2.enable = lib.mkDefault false;
    boot.kernelParams = [ "8250.nr_uarts=1" ];
    boot.swraid.enable = lib.mkDefault false;
    networking.useNetworkd = lib.mkDefault true;
    systemd.network.wait-online.enable = lib.mkDefault false;
    systemd.tpm2.enable = lib.mkDefault false;
    system.switch.enable = lib.mkDefault false;

    # The hermes activation script (config.yaml/.env seeding) runs before
    # systemd — these must already be mounted in the initrd.
    fileSystems.${guestStateDir}.neededForBoot = true;
    fileSystems.${guestHostDir}.neededForBoot = true;

    # Shutdown deadlock workaround (microvm.nix#170): systemd must not try
    # to unmount /nix/store — umount itself lives there.
    systemd.mounts = [
      {
        what = "store";
        where = "/nix/store";
        overrideStrategy = "asDropin";
        unitConfig.DefaultDependencies = false;
      }
    ];

    # Only reachable via slirp forwards; guest firewall adds nothing.
    networking.firewall.enable = false;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
      settings.PermitRootLogin = "no";
      authorizedKeysFiles = [ "${guestHostDir}/ssh/authorized_keys" ];
      hostKeys = [
        {
          path = "${guestHostDir}/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };

    # Timezone tracks the host: /etc/localtime points into the live host
    # share; the host path unit re-mirrors it on change. New processes see
    # the new zone immediately; already-running daemons keep their cached
    # TZ (normal glibc behavior, same as on the host).
    time.timeZone = null;
    systemd.tmpfiles.rules = [
      "L+ /etc/localtime - - - - ${guestHostDir}/tz/localtime"
    ];

    # Same name/uid as on the host so the shared home keeps ownership.
    users.users.${user} = {
      isNormalUser = true;
      uid = ucfg.uid;
      group = "users";
      home = "/home/${user}";
      createHome = false;
      extraGroups = [ "wheel" ];
    };
    # Self-modification parity with the old container (sudo NOPASSWD).
    security.sudo.wheelNeedsPassword = false;

    services.hermes-agent = {
      enable = true;
      user = user;
      group = "users";
      createUser = false;
      stateDir = guestStateDir;
      addToSystemPackages = true;
      settings = cfg.settings;
      environment = cfg.environment // ucfg.environment;
      environmentFiles = [ "${guestHostDir}/secrets/hermes.env" ];
      extraPlugins = cfg.extraPlugins;
      extraPackages = baseGuestPackages ++ cfg.extraPackages;
      mcpServers = lib.optionalAttrs ucfg.spacesGateway.enable {
        spaces = {
          command = "${pkgs.socat}/bin/socat";
          args = [ "STDIO" "TCP:${slirpHostAlias}:${toString ucfg.spacesPort}" ];
        };
      };
    };

    systemd.services.hermes-agent = {
      after = [ "hermes-python-venv.service" ];
      wants = [ "hermes-python-venv.service" ];
      unitConfig.RequiresMountsFor = [ guestStateDir "/home/${user}" ];
      # venv first so python/pip resolve to the writable interpreter.
      # NOTE: systemd `path` string entries get /bin appended — pass the
      # venv ROOT, not its bin dir (".venv/bin" rendered as ".venv/bin/bin"
      # and silently dropped the venv from the unit's PATH).
      path = [ guestVenv ];
      # pip-installed manylinux extension modules (.so) are loaded by the
      # nix-built interpreter, so their NEEDED libs resolve via
      # LD_LIBRARY_PATH — nix-ld doesn't apply to dlopen.
      environment.LD_LIBRARY_PATH = wheelLibraryPath;
      # Defensive: strip interpreter-hijacking keys from the writable .env.
      # load_hermes_dotenv() imports that file into the gateway's process
      # env, which the terminal tool passes into every subprocess — a
      # persisted PYTHONPATH shadows the venv's site-packages with the
      # gateway's own sealed cp312 venv (wrong-ABI imports). Upstream's
      # env writer denylists exactly these keys; a sudo-wielding agent can
      # still hand-edit them in, so drop them before every start.
      preStart = ''
        env_file=${guestStateDir}/.hermes/.env
        if [ -f "$env_file" ]; then
          ${pkgs.gnused}/bin/sed -i -E \
            '/^(export[[:space:]]+)?(PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|NIX_PYTHONPATH)=/d' \
            "$env_file"
        fi
      '';
      # The upstream unit only allows stateDir+workspace; the agent must
      # also reach the owner's shared home.
      serviceConfig.ReadWritePaths = [ "/home/${user}" ];
    };

    # Writable python: venv over the nixpkgs scientific interpreter.
    # --system-site-packages exposes every preinstalled library while
    # `pip install` lands in the venv. Recreated when the interpreter
    # changes (pip-installed extras are lost then — same lifecycle as the
    # old container's writable layer).
    systemd.services.hermes-python-venv = {
      description = "Hermes agent python venv (pip-writable)";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ guestStateDir ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        venv=${guestVenv}
        if [ ! -x "$venv/bin/python" ] \
           || [ "$(cat "$venv/.nix-python" 2>/dev/null || true)" != "${pythonEnv}" ]; then
          rm -rf "$venv"
          ${pythonEnv}/bin/python -m venv --system-site-packages "$venv"
          printf '%s' "${pythonEnv}" > "$venv/.nix-python"
          chown -R ${user}:users "$venv"
        fi
      '';
    };

    # Web dashboard (SPA + JSON-RPC/WS backend). Separate process from the
    # gateway by upstream design; shares state via HERMES_HOME. Loopback
    # bind: non-loopback binds engage the upstream cookie-only auth gate,
    # which the desktop's static remote token cannot pass — so the
    # dashboard runs in loopback mode with the host-fixed session token,
    # and the socat bridge below fronts the slirp forward.
    systemd.services.hermes-dashboard = {
      description = "Hermes Agent web dashboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "hermes-python-venv.service" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ guestStateDir guestHostDir ];
      environment = {
        HOME = guestStateDir;
        HERMES_HOME = "${guestStateDir}/.hermes";
        HERMES_MANAGED = "true";
      };
      path = [
        config.services.hermes-agent.package
        pkgs.bash
        pkgs.coreutils
        pkgs.git
        "${guestVenv}/bin"
      ] ++ baseGuestPackages ++ cfg.extraPackages;
      serviceConfig = {
        User = user;
        Group = "users";
        EnvironmentFile = "${guestHostDir}/secrets/dashboard.env";
        ExecStart = lib.concatStringsSep " " [
          "${config.services.hermes-agent.package}/bin/hermes"
          "dashboard"
          "--no-open"
          "--host"
          "127.0.0.1"
          "--port"
          (toString dashboardGuestBackendPort)
        ];
        WorkingDirectory = guestWorkspace;
        Restart = "always";
        RestartSec = 5;
        UMask = "0007";
      };
    };

    # slirp hostfwd can only target the guest NIC, so bridge NIC:9119 to
    # the loopback dashboard. Every forwarded client thus looks "loopback"
    # to upstream; the real boundary is the host's iptables owner match on
    # the forwarded port (owner uid + root only).
    systemd.services.hermes-dashboard-proxy = {
      description = "Hermes dashboard guest-side proxy for the slirp forward";
      wantedBy = [ "multi-user.target" ];
      after = [ "hermes-dashboard.service" ];
      serviceConfig = {
        DynamicUser = true;
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.socat}/bin/socat"
          "TCP-LISTEN:${toString dashboardGuestPort},fork,reuseaddr"
          "TCP:127.0.0.1:${toString dashboardGuestBackendPort}"
        ];
        Restart = "always";
        RestartSec = 5;
      };
    };

    # manylinux wheels from pip need a link-loader + common shared libs
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = nixLdLibraries;

    environment.systemPackages = [ pkgs.socat ]
      ++ lib.optional ucfg.clipboard.enable (clipboardShimFor ucfg);
    # interactive ssh/TUI shells also get the writable venv first, and the
    # wheel shared libs (same LD_LIBRARY_PATH rationale as the gateway unit)
    environment.extraInit = ''
      export PATH="${guestVenv}/bin:$PATH"
      export LD_LIBRARY_PATH="${wheelLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    '';
  };

  # ── Host-side wiring per user ─────────────────────────────────────────
  # Host-side per-user pieces. NOTE: assembled under static top-level
  # option keys below — a config-dependent mkMerge list at the config root
  # makes option-key resolution depend on cfg.users (infinite recursion).
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.users);

  # Case arms mapping the invoking user to their VM's ports.
  userCaseArms = lib.concatStrings (lib.mapAttrsToList (user: ucfg: ''
    ${user})
      ssh_port=${toString ucfg.sshPort}
      dashboard_port=${toString ucfg.dashboardPort}
      ;;
  '') cfg.users);

  # Host CLI shim: routes every `hermes` invocation into the caller's VM
  # (microvm equivalent of the old .container-mode docker-exec seam).
  hermesShim = pkgs.writeShellScriptBin "hermes" ''
    # The desktop app is a host-side GUI (guests are headless): route the
    # upstream `hermes desktop` subcommand to the hermes-desktop wrapper
    # instead of ssh-execing it into the VM.
    if [ "''${1:-}" = "desktop" ]; then
      shift
      exec ${hermesDesktop}/bin/hermes-desktop "$@"
    fi
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${userCaseArms}
    *)
      echo "hermes: no hermes microvm configured for user $u" >&2
      exit 1
      ;;
    esac
    # Fail fast while the VM is down (ssh would fail closed on the pinned
    # host key anyway, but with a less helpful error).
    ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@hermes-$u.service" || {
      echo "hermes: microvm@hermes-$u is not running (systemctl status microvm@hermes-$u)" >&2
      exit 1
    }
    base="/var/lib/hermes-microvm/$u"
    tty_flag=""
    if [ -t 0 ] && [ -t 1 ]; then tty_flag="-t"; fi
    # ssh only carries TERM; the old docker-exec routing also passed
    # COLORTERM/LANG/LC_ALL (TUI colors + UTF-8 glyphs). Embed them into
    # the remote command, shell-quoted. WAYLAND_DISPLAY gates hermes's
    # wayland clipboard path in the guest (served by the bridged wl-paste
    # shim, which ignores the value).
    env_exports=""
    for v in COLORTERM LANG LC_ALL WAYLAND_DISPLAY; do
      eval "val=\''${$v:-}"
      if [ -n "$val" ]; then
        env_exports="$env_exports export $v=$(printf '%q' "$val") &&"
      fi
    done
    remote_cmd="$env_exports cd ${guestWorkspace} && export HERMES_HOME=${guestStateDir}/.hermes && exec /run/current-system/sw/bin/hermes"
    # printf %q with zero args would still emit one empty-string argument
    if [ "$#" -gt 0 ]; then remote_cmd="$remote_cmd $(printf '%q ' "$@")"; fi
    exec ${pkgs.openssh}/bin/ssh $tty_flag \
      -p "$ssh_port" \
      -i "$base/ssh/client_ed25519" \
      -o IdentitiesOnly=yes \
      -o UserKnownHostsFile="$base/ssh/known_hosts" \
      -o StrictHostKeyChecking=yes \
      "$u@127.0.0.1" -- \
      "$remote_cmd"
  '';

  hermesInfo = pkgs.writeShellScriptBin "hermes-vm-info" ''
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${userCaseArms}
    *)
      echo "hermes-vm-info: no hermes microvm configured for user $u" >&2
      exit 1
      ;;
    esac
    ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@hermes-$u.service" \
      || { echo "hermes-vm-info: microvm@hermes-$u is not running" >&2; exit 1; }
    base="/var/lib/hermes-microvm/$u"
    echo "VM:            microvm@hermes-$u.service"
    echo "CLI/TUI:       hermes (routed via ssh, port $ssh_port)"
    # Loopback mode serves the SPA unauthenticated and injects the session
    # token itself; a ?token= URL would only leak the secret into shell
    # history. Point at the file instead.
    echo "Dashboard:     http://127.0.0.1:$dashboard_port/"
    echo "  token file:  $base/desktop-token (for API/WS clients)"
    echo "Desktop:       hermes-desktop (upstream Electron app -> this VM's backend)"
  '';

  # Upstream Electron desktop app (nixpkgs electron + npm-built renderer).
  desktopPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop;

  # Host desktop launcher: the upstream app in remote-backend mode against
  # the owner's forwarded dashboard instead of spawning a local python
  # backend. Token file is 0400 owner-only and the port is uid-gated by
  # iptables, so the exported token stays owner-confined.
  hermesDesktop = pkgs.writeShellScriptBin "hermes-desktop" ''
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${userCaseArms}
    *)
      echo "hermes-desktop: no hermes microvm configured for user $u" >&2
      exit 1
      ;;
    esac
    base="/var/lib/hermes-microvm/$u"
    # Refuse while the VM is down: its loopback port is then free for any
    # local user to squat (owner-match gates connects, not listens).
    ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@hermes-$u.service" || {
      echo "hermes-desktop: microvm@hermes-$u is not running — refusing to send the token to a possibly squatted port" >&2
      exit 1
    }
    token="$(${pkgs.coreutils}/bin/cat "$base/desktop-token" 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "hermes-desktop: cannot read $base/desktop-token (VM not provisioned yet?)" >&2
      exit 1
    fi
    export HERMES_DESKTOP_REMOTE_URL="http://127.0.0.1:$dashboard_port"
    export HERMES_DESKTOP_REMOTE_TOKEN="$token"
    exec ${desktopPackage}/bin/hermes-desktop "$@"
  '';
  # Launcher visibility: neither the upstream desktop package nor the
  # shims above ship .desktop files, so app launchers (fuzzel drun) never
  # list Hermes. Two entries, both against the host wrappers (absolute
  # store paths — launchers don't inherit a useful PATH):
  #   - Hermes Desktop: the Electron app via the token-injecting wrapper.
  #   - Hermes TUI: Terminal=true; fuzzel's default `terminal=$TERMINAL -e`
  #     resolves via desktop.nix's TERMINAL=alacritty. Wrapped so a fast
  #     failure (VM down) doesn't just flash and vanish with the window.
  hermesIcon = "${desktopPackage}/share/hermes-desktop/dist/hermes.png";

  hermesTuiLauncher = pkgs.writeShellScriptBin "hermes-tui" ''
    ${hermesShim}/bin/hermes "$@"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '\nhermes exited with status %d — press Enter to close\n' "$rc"
      read -r _
    fi
    exit "$rc"
  '';

  hermesDesktopItem = pkgs.makeDesktopItem {
    name = "hermes-desktop";
    desktopName = "Hermes Desktop";
    comment = "Hermes Agent desktop app (microvm backend)";
    exec = "${hermesDesktop}/bin/hermes-desktop";
    icon = hermesIcon;
    categories = [ "Network" "Chat" ];
  };

  hermesTuiItem = pkgs.makeDesktopItem {
    name = "hermes-tui";
    desktopName = "Hermes TUI";
    comment = "Hermes Agent terminal UI (ssh into the microvm)";
    exec = "${hermesTuiLauncher}/bin/hermes-tui";
    icon = hermesIcon;
    terminal = true;
    categories = [ "Network" "ConsoleOnly" ];
  };

  # Only the owner (and root) may connect to a VM's forwarded loopback
  # ports; only qemu (`microvm` user), the owner, and root may reach the
  # spaces bridge.
  ownerOnlyRules = port: uid: ''
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner ${toString uid} -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner 0 -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -j REJECT --reject-with tcp-reset
  '';
  firewallRules = lib.concatStrings (lib.mapAttrsToList (user: ucfg: ''
    ${ownerOnlyRules ucfg.sshPort ucfg.uid}
    ${ownerOnlyRules ucfg.dashboardPort ucfg.uid}
    ${lib.optionalString ucfg.spacesGateway.enable ''
      iptables -w -A hermes-microvm -p tcp --dport ${toString ucfg.spacesPort} -m owner --uid-owner microvm -j RETURN
      ${ownerOnlyRules ucfg.spacesPort ucfg.uid}
    ''}
    ${lib.optionalString ucfg.clipboard.enable ''
      iptables -w -A hermes-microvm -p tcp --dport ${toString ucfg.clipboardPort} -m owner --uid-owner microvm -j RETURN
      ${ownerOnlyRules ucfg.clipboardPort ucfg.uid}
    ''}
  '') cfg.users);
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  options.services.hermes-microvm = with lib; {
    enable = mkEnableOption "per-user Hermes agent MicroVMs";

    settings = mkOption {
      type = types.attrs;
      default = { };
      description = "Hermes settings, passed to the upstream module in every guest.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Non-secret env vars for every guest's hermes .env.";
    };

    extraPlugins = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Hermes plugin packages, installed in every guest.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Guest packages on the agent's PATH, in addition to the built-in toolset.";
    };

    pythonPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      description = "Python libraries preinstalled in every guest's writable venv.";
      default = ps: with ps; [
        # math / data (openblas-accelerated), CPU torch (AVX-512), numba JIT
        numpy
        scipy
        sympy
        pandas
        polars
        pyarrow
        duckdb
        matplotlib
        seaborn
        scikit-learn
        statsmodels
        networkx
        numba
        pillow
        tqdm
        # ML
        torch
        transformers
        # research / documents
        pypdf
        openpyxl
        python-docx
        # (nixpkgs `arxiv` currently fails its runtime-deps check; agents
        # can `pip install arxiv` into the venv when needed)
        wikipedia
        # crawling / web
        requests
        httpx
        aiohttp
        beautifulsoup4
        lxml
        html5lib
        feedparser
        trafilatura
        scrapy
        # misc
        pyyaml
        rich
        ipython
      ];
    };

    vcpu = mkOption {
      type = types.int;
      default = 8;
      description = "vCPUs per guest.";
    };

    mem = mkOption {
      type = types.int;
      default = 8192;
      description = "Guest RAM in MiB.";
    };

    stateSize = mkOption {
      type = types.int;
      default = 20480;
      description = "Size of the per-user hermes state volume in MiB.";
    };

    users = mkOption {
      default = { };
      description = "Users that get their own Hermes microvm.";
      type = types.attrsOf (types.submodule ({ config, ... }: {
        options = {
          uid = mkOption {
            type = types.int;
            description = "The user's uid on the host (mirrored in the guest).";
          };
          sshPort = mkOption {
            type = types.port;
            default = 22000 + config.uid - 1000;
            description = "Host 127.0.0.1 port forwarded to the guest's sshd.";
          };
          dashboardPort = mkOption {
            type = types.port;
            default = 22100 + config.uid - 1000;
            description = "Host 127.0.0.1 port forwarded to the guest dashboard.";
          };
          spacesPort = mkOption {
            type = types.port;
            default = 22200 + config.uid - 1000;
            description = "Host 127.0.0.1 port of the spaces gateway TCP bridge.";
          };
          clipboardPort = mkOption {
            type = types.port;
            default = 22300 + config.uid - 1000;
            description = "Host 127.0.0.1 port of the clipboard bridge.";
          };
          environment = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = "Per-user non-secret env vars for the guest's hermes .env.";
          };
          environmentFiles = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Host paths of secret env files, assembled into the guest's hermes .env.";
          };
          clipboard = {
            enable = mkEnableOption "bridging the user's Wayland clipboard into the VM, read-only (TUI image paste)";
          };
          spacesGateway = {
            enable = mkEnableOption "bridging the user's spaces integration gateway into the VM";
            socket = mkOption {
              type = types.str;
              default = "/run/user/${toString config.uid}/spaces-integration-gateway.sock";
              description = "The per-user spaces gateway socket on the host.";
            };
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (user: ucfg: {
      assertion = lib.count (u: u.uid == ucfg.uid) (lib.attrValues cfg.users) == 1;
      message = "services.hermes-microvm: duplicate uid ${toString ucfg.uid} (${user}) — uids derive ports, MAC and firewall identity and must be unique";
    }) cfg.users;

    environment.systemPackages = [
      hermesShim hermesInfo hermesDesktop
      hermesDesktopItem hermesTuiItem
    ];

    networking.firewall.extraCommands = ''
      iptables -w -N hermes-microvm 2>/dev/null || true
      iptables -w -F hermes-microvm
      ${firewallRules}
      iptables -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
        || iptables -w -A OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm
    '';
    networking.firewall.extraStopCommands = ''
      iptables -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
      iptables -w -F hermes-microvm 2>/dev/null || true
      iptables -w -X hermes-microvm 2>/dev/null || true
    '';

    microvm.vms = lib.mapAttrs' (user: ucfg:
      lib.nameValuePair (vmName user) {
        config = guestConfig user ucfg;
        # autostart + restart-on-rebuild are the defaults for fully-
        # declarative VMs; listed here for greppability.
        autostart = true;
      }
    ) cfg.users;

    # Re-mirror the timezone whenever the host's /etc/localtime symlink is
    # swapped (timedatectl, automatic-timezoned, rebuild activation).
    systemd.paths.hermes-microvm-timezone = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "/etc/localtime";
    };

    systemd.services = lib.mkMerge [
      {
        hermes-microvm-timezone = {
          description = "Mirror host timezone into hermes microvm shares";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${tzSyncScript}";
          };
        };
      }
      (forEachUser (user: ucfg: {
      "microvm@${vmName user}" = {
        # "+" = run with full privileges (the unit itself runs as `microvm`)
        serviceConfig.ExecStartPre = [ "+${provisionScript user ucfg}" ];
      } // lib.optionalAttrs ucfg.spacesGateway.enable {
        # the spaces gateway socket lives in the owner's user session
        after = [ "user@${toString ucfg.uid}.service" ];
        wants = [ "user@${toString ucfg.uid}.service" ];
      };

      # spaces gateway bridge: guest socat -> 10.0.2.2:<port> -> this unit
      # (running as the owner, who alone may open the 0700 user socket).
      "hermes-spaces-bridge-${user}" = lib.mkIf ucfg.spacesGateway.enable {
        description = "spaces gateway TCP bridge for ${vmName user}";
        wantedBy = [ "multi-user.target" ];
        after = [ "user@${toString ucfg.uid}.service" ];
        wants = [ "user@${toString ucfg.uid}.service" ];
        serviceConfig = {
          User = user;
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.socat}/bin/socat"
            "TCP-LISTEN:${toString ucfg.spacesPort},bind=127.0.0.1,fork,reuseaddr"
            "UNIX-CONNECT:${ucfg.spacesGateway.socket}"
          ];
          Restart = "always";
          RestartSec = 5;
        };
      };

      # clipboard bridge: guest wl-paste shim -> slirp 10.0.2.2:<port> ->
      # this unit (as the owner) -> real wl-paste against the session
      # compositor. Read-only by construction (paste only, whitelisted
      # request forms).
      "hermes-clipboard-bridge-${user}" = lib.mkIf ucfg.clipboard.enable {
        description = "host clipboard bridge for ${vmName user}";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = user;
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.socat}/bin/socat"
            "TCP-LISTEN:${toString ucfg.clipboardPort},bind=127.0.0.1,fork,reuseaddr"
            "EXEC:${clipboardServer user ucfg}"
          ];
          Restart = "always";
          RestartSec = 5;
        };
      };
      }))
    ];

    # Share sources must exist before virtiofsd starts; contents are
    # filled by the provisioning ExecStartPre.
    systemd.tmpfiles.rules =
      [ "d /var/lib/hermes-microvm 0755 root root - -" ]
      ++ lib.concatLists (lib.mapAttrsToList (user: _: [
        "d ${baseDir user} 0755 root root - -"
        "d ${baseDir user}/ssh 0755 root root - -"
        "d ${baseDir user}/guest 0755 root root - -"
        "d ${baseDir user}/guest/ssh 0755 root root - -"
        "d ${baseDir user}/guest/secrets 0700 root root - -"
      ]) cfg.users);

    # The per-user gateway socket must exist at boot, before any
    # interactive login.
    users.users = forEachUser (user: ucfg: {
      ${user} = {
        # Pin the host uid to the configured one: firewall owner-match,
        # guest account, home-share ownership and port/MAC derivation all
        # assume they agree. A drifted auto-allocated uid would authorize
        # the wrong account silently.
        uid = ucfg.uid;
      } // lib.optionalAttrs ucfg.spacesGateway.enable {
        linger = true;
      };
    });
  };
}
