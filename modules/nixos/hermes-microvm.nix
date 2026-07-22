# Hermes Agent (NousResearch) in per-user MicroVMs — microvm.nix, fully
# declarative, qemu + slirp user networking (no host bridge/NAT).
#
# One VM per user ("hermes-<user>"); the upstream hermes NixOS module runs
# natively in each guest as an account mirroring the host user's name/uid,
# with passwordless sudo. /home/<user>/hermes is the path-identity
# exchange dir (same absolute path on both sides, also the guest HOME);
# artifacts land in /home/<user>/hermes/workspace, hermes state (.hermes
# DBs, .venv) in a hidden vault.
#
# Host <-> guest interfaces (per user, all on 127.0.0.1):
#   - `hermes` CLI/TUI: host shim ssh-execs into the VM (per-user keypair).
#   - Web dashboard: guest socat bridges loopback :9118 to the :9119 slirp
#     forward -> host <dashboardPort>; auth = fixed host-generated token.
#   - `hermes-desktop`: Electron app against the forwarded dashboard.
#   - spaces MCP: guest socat -> 10.0.2.2:<spacesPort> -> host socat (as
#     the owner) -> the per-user gateway socket.
# Isolation: owner-only key/token files + iptables OUTPUT owner-match on
# every forwarded port. Caveats (fine for one user): guests share the
# `microvm` uid, so one guest can reach another user's spaces bridge; and
# owner-match gates connects, not listens — a down VM's port can be
# squatted (ssh/wrappers fail closed; a browser could still be phished).
#
# State vault: guest /var/lib/hermes is virtiofs from the host's
# /var/lib/hermes-microvm/<user>/state-vault/state (0700 root), which only
# the virtiofsd unit sees (bind mount in its private mount namespace over
# an empty decoy source under /run/hermes-microvm-shares/<user>/).
# INVARIANT: the host must NEVER open the state sqlite DBs (virtiofs: no
# cross-kernel locks, unsafe WAL mmap) — inspect via the guest, or:
#   nsenter -m -t "$(systemctl show -p MainPID --value microvm-virtiofsd@hermes-<user>)"
# The guest runs hermesPackageNoWal (journal_mode=DELETE everywhere).
#
# pip venv: see ./hermes-guest-python.nix (pinned by a flake check).
# GPU: `gpu.enable` = Vulkan via QEMU Venus on the shared host iGPU.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.hermes-microvm;

  vmName = user: "hermes-${user}";
  baseDir = user: "/var/lib/hermes-microvm/${user}";
  # State-vault share sources: empty decoy dirs in the host namespace; the
  # real vault is bind-mounted over them only inside the virtiofsd unit.
  shareSourceDir = user: "/run/hermes-microvm-shares/${user}";

  # Fixed guest paths
  guestStateDir = "/var/lib/hermes";
  guestHostDir = "/run/hermes-host"; # ro virtiofs: ssh keys + secrets
  # Exchange dir: same absolute path in the guest, and the guest HOME.
  exchangeDir = user: "/home/${user}/hermes";
  guestWorkspace = user: "${exchangeDir user}/workspace";
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

  # Root ExecStartPre of microvm@hermes-<user>: per-user keys, dashboard
  # token, guest secret env files, VM state dir lockdown, spaces wait.
  provisionScript = user: ucfg: pkgs.writeShellScript "hermes-microvm-provision-${user}" ''
    set -eu
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils gawk openssh openssl ])}
    base=${baseDir user}
    # dirs come from the tmpfiles rules; only secret material that cannot
    # live in the world-readable nix store is generated here.

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

    # dashboard session token; the 0400 owner-readable copy doubles as
    # HERMES_DESKTOP_REMOTE_TOKEN for the hermes-desktop wrapper.
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

    # VM runtime dir (virtiofsd sockets, current-system symlink) — no
    # world access.
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
  # into every guest share dir. A mount can't: the host tz is a symlink
  # into /etc, and sharing /etc would leak secrets. Runs at provisioning
  # and on every /etc/localtime swap.
  tzSyncScript = pkgs.writeShellScript "hermes-microvm-tz-sync" ''
    set -eu
    # Own the umask: callers may run under umask 077, which once produced
    # an untraversable tz dir (guest fell back to UTC); chmod repairs.
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

  # ── Guest hermes package: sqlite WAL disabled ────────────────────────
  # WAL: on virtiofs (cache=auto) `PRAGMA journal_mode=WAL` SUCCEEDS but
  # the -shm mmap's FUSE cache invalidation is unreliable — a corruption
  # risk, not a clean failure — so upstream's WAL->DELETE fallback
  # (hermes_state.apply_wal_with_fallback) never fires, and several files
  # set WAL raw with no fallback at all. No config/env knob exists, so
  # the wheel is patched to force journal_mode=DELETE everywhere. The
  # upstream package is a bin-wrapper around a sealed uv2nix venv (a
  # symlink farm over per-wheel store paths): copy the farm, embed a
  # patched wheel, retarget the farm's links, re-point the wrapper. A
  # build-time grep proves no WAL set-pragma survives.
  hermesPackageBase = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;

  hermesVenvNoWal = pkgs.runCommand "${hermesPackageBase.hermesVenv.name}-nowal" { } ''
    orig=${hermesPackageBase.hermesVenv}
    sp=$(cd "$orig" && echo lib/python3.*/site-packages)
    wheel=$(readlink "$orig/$sp/hermes_state.py")
    wheel=''${wheel%/lib/*}

    mkdir $out
    cp -a "$orig/." "$out/"
    chmod u+w "$out"
    cp -a "$wheel" "$out/pkg"
    chmod -R u+w "$out"

    # Neuter the keep-existing-WAL probe, then turn the WAL set-pragma
    # into DELETE + early return (the rest of the function goes dead).
    substituteInPlace "$out/pkg/$sp/hermes_state.py" \
      --replace-fail 'if current_mode and current_mode[0] == "wal":' \
                     'if False and current_mode and current_mode[0] == "wal":  # hyperconfig: DELETE-only on virtiofs' \
      --replace-fail 'conn.execute("PRAGMA journal_mode=WAL")' \
                     'conn.execute("PRAGMA journal_mode=DELETE"); return "delete"  # hyperconfig: DELETE-only on virtiofs'
    # Raw WAL set-pragmas with no fallback: force DELETE directly.
    for f in agent/verification_evidence.py tools/async_delegation.py \
             cron/executions.py gateway/delivery_ledger.py \
             plugins/platforms/discord/recovery.py; do
      substituteInPlace "$out/pkg/$sp/$f" \
        --replace-fail 'conn.execute("PRAGMA journal_mode=WAL")' \
                       'conn.execute("PRAGMA journal_mode=DELETE")'
    done

    # Stale bytecode would shadow the patched sources.
    for f in hermes_state.py agent/verification_evidence.py \
             tools/async_delegation.py cron/executions.py \
             gateway/delivery_ledger.py plugins/platforms/discord/recovery.py; do
      d=$(dirname "$f"); b=$(basename "$f" .py)
      rm -f "$out/pkg/$sp/$d/__pycache__/$b."*.pyc
    done
    if grep -RF 'execute("PRAGMA journal_mode=WAL")' "$out/pkg" --include='*.py'; then
      echo "hermes-microvm: unpatched WAL set-pragma sites remain" >&2
      exit 1
    fi

    # Retarget every farm symlink from the original wheel to the patch.
    find "$out" -type l | while read -r l; do
      t=$(readlink "$l")
      case "$t" in
        "$wheel"/*) ln -sfT "$out/pkg''${t#"$wheel"}" "$l" ;;
        "$wheel")   ln -sfT "$out/pkg" "$l" ;;
      esac
    done
    # Symlinks to the .pyc files removed above are now dangling — drop
    # them (python stats the pyc, misses, and compiles from source).
    find "$out" -xtype l -delete
    # Venv self-references (console-script shebangs, activate scripts).
    (grep -rlI "$orig" "$out" || true) | while read -r f; do
      sed -i "s|$orig|$out|g" "$f"
    done
  '';

  # Same bin wrappers (skills/plugins/web_dist untouched), exec line +
  # HERMES_PYTHON re-pointed at the WAL-free venv.
  hermesPackageNoWal = pkgs.runCommand hermesPackageBase.name { } ''
    mkdir $out
    cp -a ${hermesPackageBase}/. $out/
    chmod -R u+w $out
    (grep -rlI ${hermesPackageBase.hermesVenv} "$out" || true) | while read -r f; do
      sed -i "s|${hermesPackageBase.hermesVenv}|${hermesVenvNoWal}|g" "$f"
    done
  '';

  # ExecStartPre of the per-VM virtiofsd unit: bind the state vault over
  # the decoy inside the unit's private mount namespace, and re-assert
  # EVERY share source so a state wipe can't wedge the Type=notify unit
  # (tmpfiles only runs at boot/rebuild; this runs at every start).
  vaultBindScript = user: pkgs.writeShellScript "hermes-vault-bind-${user}" ''
    set -eu
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils util-linux ])}
    install -d -m 0700 -o root -g root ${baseDir user}/state-vault
    install -d -m 0700 -o ${user} -g users ${baseDir user}/state-vault/state
    install -d -m 0755 ${baseDir user}/state-vault/state/simplex
    mkdir -p ${shareSourceDir user}
    install -d -m 0700 -o root -g root ${shareSourceDir user}/state
    # host-config share source; contents provisioned later by microvm@'s
    # ExecStartPre — the dir just has to exist
    install -d -m 0755 -o root -g root ${baseDir user}/guest
    # exchange dir share source (/home/<user> itself is the owner's real
    # home — never created or chowned here)
    install -d -m 0755 -o ${user} -g users ${exchangeDir user}
    install -d -m 0755 -o ${user} -g users ${guestWorkspace user}
    mount --bind ${baseDir user}/state-vault/state ${shareSourceDir user}/state
  '';

  # ── Guest NixOS configuration (fully declarative microvm) ────────────
  guestConfig = user: ucfg: { config, lib, pkgs, ... }: {
    imports = [
      inputs.hermes-agent.nixosModules.default
      ./hermes-guest-python.nix
      ./simplex-chat.nix
    ];

    # SimpleX daemon lives INSIDE the guest; its SQLite state persists on
    # the vault share. Accepted amber risk: simplex likely runs WAL on
    # virtiofs — worst case is re-pairing contacts.
    services.simplex-chat-daemon = lib.mkIf cfg.simplex.enable {
      enable = true;
      allowedUsers = cfg.simplex.allowedUsers;
    };
    fileSystems."/var/lib/simplex-chat" = lib.mkIf cfg.simplex.enable {
      device = "${guestStateDir}/simplex";
      fsType = "none";
      options = [ "bind" ];
    };

    services.hermes-python = {
      enable = true;
      inherit user;
      stateDir = guestStateDir;
      packages = cfg.pythonPackages;
    };

    networking.hostName = vmName user;
    system.stateVersion = "26.05";

    microvm = {
      hypervisor = "qemu";
      vcpu = cfg.vcpu;
      mem = cfg.mem;
      # slirp: outbound internet with zero host network setup; inbound
      # only through the explicit forwards below.
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
          # Path-identity exchange: host ~/hermes IS guest ~/hermes (also
          # the guest HOME), owner-auditable, never GC'd by hermes. Do not
          # open live SQLite DBs in here from the host while the VM runs.
          proto = "virtiofs";
          tag = "hermes-exchange";
          source = exchangeDir user;
          mountPoint = exchangeDir user;
        }
        {
          proto = "virtiofs";
          tag = "host-config";
          source = "${baseDir user}/guest";
          mountPoint = guestHostDir;
          readOnly = true;
        }
        {
          # HERMES state from the namespace-hidden vault (source is the
          # decoy; virtiofsd bind-mounts the real vault over it). cache
          # stays "auto": the guest never uses WAL (hermesPackageNoWal),
          # and exec/MAP_PRIVATE mmaps in .venv need the page cache.
          proto = "virtiofs";
          tag = "hermes-state";
          source = "${shareSourceDir user}/state";
          mountPoint = guestStateDir;
        }
      ];
      # Writable store overlay so `nix` works inside the guest.
      writableStoreOverlay = "/nix/.rw-store";

      # Venus: qemu renders on the host render node via egl-headless;
      # hostmem is a PCI BAR window for mapped blobs, not a RAM
      # reservation. Appended after the runner's `-nographic` — the later
      # -display wins and the serial console redirection is kept.
      qemu.extraArgs = lib.optionals cfg.gpu.enable [
        "-display" "egl-headless,rendernode=/dev/dri/renderD128"
        "-device" "virtio-gpu-gl-pci,hostmem=${cfg.gpu.hostmem},blob=true,venus=true"
      ];
      # microvm.optimize swaps in a qemu built without SDL/OpenGL/virgl/
      # venus — disable it when gpu is on; its defaults are pinned below.
      optimize.enable = !cfg.gpu.enable;
    };

    # microvm.optimize defaults pinned explicitly so gpu.enable regresses
    # nothing. One divergence from upstream: system.switch stays off —
    # these guests are fully declarative.
    documentation.enable = lib.mkDefault false;
    boot.initrd.systemd.enable = lib.mkDefault true;
    boot.initrd.systemd.tpm2.enable = lib.mkDefault false;
    boot.kernelParams = [ "8250.nr_uarts=1" ];
    boot.swraid.enable = lib.mkDefault false;
    networking.useNetworkd = lib.mkDefault true;
    systemd.network.wait-online.enable = lib.mkDefault false;
    systemd.tpm2.enable = lib.mkDefault false;
    system.switch.enable = lib.mkDefault false;

    # Venus guest side: virtio-gpu DRM device + mesa Vulkan ICD.
    # microvm.nix blacklists drm whenever its graphics option is off —
    # reproduce its blacklist minus drm.
    boot.blacklistedKernelModules = lib.mkIf cfg.gpu.enable (lib.mkForce [ "rfkill" "intel_pstate" ]);
    boot.kernelModules = lib.optionals cfg.gpu.enable [ "virtio_gpu" ];
    hardware.graphics.enable = cfg.gpu.enable;

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

    # Timezone tracks the host via the mirrored file; already-running
    # daemons keep their cached TZ (normal glibc behavior).
    time.timeZone = null;
    systemd.tmpfiles.rules = [
      "L+ /etc/localtime - - - - ${guestHostDir}/tz/localtime"
    ];

    # Same name/uid as the host so share ownership maps 1:1. HOME is the
    # exchange dir; hermes state stays on the vault — HERMES_HOME is set
    # explicitly at every entry point, nothing falls back to ~/.hermes.
    users.users.${user} = {
      isNormalUser = true;
      uid = ucfg.uid;
      group = "users";
      home = exchangeDir user;
      createHome = false;
      # render/video: Vulkan on the virtio-gpu render node (Venus).
      extraGroups = [ "wheel" ] ++ lib.optionals cfg.gpu.enable [ "render" "video" ];
    };
    # Self-modification parity: sudo NOPASSWD.
    security.sudo.wheelNeedsPassword = false;

    services.hermes-agent = {
      enable = true;
      # WAL-free build: state.db & friends live on virtiofs (see header).
      package = hermesPackageNoWal;
      user = user;
      group = "users";
      createUser = false;
      stateDir = guestStateDir;
      # Sessions start (and files land) in the path-identity workspace.
      workingDirectory = guestWorkspace user;
      addToSystemPackages = true;
      settings = cfg.settings;
      environment = cfg.environment // ucfg.environment
        // lib.optionalAttrs cfg.simplex.enable (
          {
            SIMPLEX_WS_URL = "ws://127.0.0.1:${toString config.services.simplex-chat-daemon.port}";
          }
          // lib.optionalAttrs (cfg.simplex.allowedUsers != [ ]) {
            SIMPLEX_ALLOWED_USERS = lib.concatStringsSep "," cfg.simplex.allowedUsers;
          }
        );
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
      unitConfig.RequiresMountsFor = [ guestStateDir (exchangeDir user) ];
      # venv first so python/pip resolve to the writable interpreter.
      # NOTE: systemd `path` string entries get /bin appended — pass the
      # venv ROOT, not its bin dir (".venv/bin" rendered as ".venv/bin/bin"
      # and silently dropped the venv from the unit's PATH).
      path = [ config.services.hermes-python.venv ];
      # pip-installed manylinux extension modules (.so) are loaded by the
      # nix-built interpreter, so their NEEDED libs resolve via
      # LD_LIBRARY_PATH — nix-ld doesn't apply to dlopen.
      environment.LD_LIBRARY_PATH = config.services.hermes-python.wheelLibraryPath;
      # Strip interpreter-hijacking keys from the writable .env: it is
      # imported into the gateway's process env and inherited by every
      # subprocess; a persisted PYTHONPATH shadows the venv with the
      # gateway's sealed cp312 venv (wrong-ABI imports). A sudo-wielding
      # agent can re-add them, so drop before every start.
      preStart = ''
        env_file=${guestStateDir}/.hermes/.env
        if [ -f "$env_file" ]; then
          ${pkgs.gnused}/bin/sed -i -E \
            '/^(export[[:space:]]+)?(PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|NIX_PYTHONPATH)=/d' \
            "$env_file"
        fi
      '';
      # Upstream hardcodes HOME=stateDir in the unit env; force the
      # exchange dir so ~ is the same path in guest and host.
      environment.HOME = lib.mkForce (exchangeDir user);
      # Upstream's ProtectSystem=strict allows only stateDir+workspace;
      # HOME sits one level above the workspace, so writes like ~/.cache
      # need the exchange dir writable too.
      serviceConfig.ReadWritePaths = [ (exchangeDir user) ];
    };

    # Web dashboard (SPA + JSON-RPC/WS backend); separate process by
    # upstream design, shares state via HERMES_HOME. Loopback bind:
    # non-loopback engages the cookie-only auth gate the desktop's static
    # remote token cannot pass.
    systemd.services.hermes-dashboard = {
      description = "Hermes Agent web dashboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "hermes-python-venv.service" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ guestStateDir (exchangeDir user) guestHostDir ];
      environment = {
        HOME = exchangeDir user;
        HERMES_HOME = "${guestStateDir}/.hermes";
        HERMES_MANAGED = "true";
      };
      path = [
        config.services.hermes-agent.package
        pkgs.bash
        pkgs.coreutils
        pkgs.git
        config.services.hermes-python.venv
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
        WorkingDirectory = guestWorkspace user;
        Restart = "always";
        RestartSec = 5;
        UMask = "0007";
      };
    };

    # slirp hostfwd can only target the guest NIC — bridge NIC:9119 to
    # the loopback dashboard. Every forwarded client thus looks
    # "loopback" to upstream; the real boundary is the host's iptables
    # owner match.
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

    environment.systemPackages = [ pkgs.socat ]
      # vulkaninfo/vkcube for smoke-testing venus
      ++ lib.optionals cfg.gpu.enable [ pkgs.vulkan-tools ];
  };

  # ── Host-side wiring per user ─────────────────────────────────────────
  # Assembled under static top-level option keys — a config-dependent
  # mkMerge list at the config root makes option-key resolution depend on
  # cfg.users (infinite recursion).
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.users);

  # Case arms mapping the invoking user to their VM's ports.
  userCaseArms = lib.concatStrings (lib.mapAttrsToList (user: ucfg: ''
    ${user})
      ssh_port=${toString ucfg.sshPort}
      dashboard_port=${toString ucfg.dashboardPort}
      ;;
  '') cfg.users);

  # Host CLI shim: routes every `hermes` invocation into the caller's VM.
  hermesShim = pkgs.writeShellScriptBin "hermes" ''
    # `hermes desktop` is a host-side GUI (guests are headless): route it
    # to the hermes-desktop wrapper instead of ssh-execing into the VM.
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
    # Fail fast while the VM is down (clearer than ssh's pinned-key error).
    ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@hermes-$u.service" || {
      echo "hermes: microvm@hermes-$u is not running (systemctl status microvm@hermes-$u)" >&2
      exit 1
    }
    base="/var/lib/hermes-microvm/$u"
    tty_flag=""
    if [ -t 0 ] && [ -t 1 ]; then tty_flag="-t"; fi
    # ssh only carries TERM; embed COLORTERM/LANG/LC_ALL shell-quoted in
    # the remote command (TUI colors + UTF-8 glyphs). Deliberately NOT
    # WAYLAND_DISPLAY: the host clipboard is never bridged into the VM —
    # hermes's clipboard path stays disabled, paste degrades gracefully.
    env_exports=""
    for v in COLORTERM LANG LC_ALL; do
      eval "val=\''${$v:-}"
      if [ -n "$val" ]; then
        env_exports="$env_exports export $v=$(printf '%q' "$val") &&"
      fi
    done
    remote_cmd="$env_exports cd /home/$u/hermes/workspace && export HERMES_HOME=${guestStateDir}/.hermes && exec /run/current-system/sw/bin/hermes"
    # printf %q with zero args would still emit one empty-string argument
    if [ "$#" -gt 0 ]; then remote_cmd="$remote_cmd $(printf '%q ' "$@")"; fi
    # ControlMaster=no: keep the user's global ssh mux config out of this
    # connection (its socket mismatch printed "disabling multiplexing"
    # noise into the TUI).
    exec ${pkgs.openssh}/bin/ssh $tty_flag \
      -p "$ssh_port" \
      -i "$base/ssh/client_ed25519" \
      -o IdentitiesOnly=yes \
      -o UserKnownHostsFile="$base/ssh/known_hosts" \
      -o StrictHostKeyChecking=yes \
      -o ControlMaster=no -o ControlPath=none \
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
    # Loopback mode serves the SPA unauthenticated; a ?token= URL would
    # only leak the secret into shell history — point at the file instead.
    echo "Dashboard:     http://127.0.0.1:$dashboard_port/"
    echo "  token file:  $base/desktop-token (for API/WS clients)"
    echo "Desktop:       hermes-desktop (upstream Electron app -> this VM's backend)"
  '';

  # Upstream Electron desktop app (nixpkgs electron + npm-built renderer).
  desktopPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop;

  # Host launcher: the upstream app in remote-backend mode against the
  # owner's forwarded dashboard. Token file 0400 + uid-gated port keep
  # the exported token owner-confined.
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
  # Neither the upstream desktop package nor the shims ship .desktop
  # files — provide launcher entries against the host wrappers (absolute
  # store paths; launchers don't inherit a useful PATH). The TUI entry is
  # Terminal=true and wraps the shim so a fast failure (VM down) doesn't
  # just flash and vanish with the window.
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
  '') cfg.users) + ''
    # Guest -> host loopback allowlist (uid microvm = anything a guest
    # sends to slirp's 10.0.2.2): the spaces-bridge RETURNs above plus DNS
    # for slirp's resolver forwarding; everything else rejected.
    iptables -w -A hermes-microvm -p tcp --dport 53 -m owner --uid-owner microvm -j RETURN
    iptables -w -A hermes-microvm -p udp --dport 53 -m owner --uid-owner microvm -j RETURN
    iptables -w -A hermes-microvm -m owner --uid-owner microvm -j REJECT
  '';
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

    gpu = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Vulkan in every guest via QEMU Venus (virtio-gpu-gl on the host
          iGPU's render node). The GPU is time-shared with the host
          desktop, not passed through.
        '';
      };
      hostmem = mkOption {
        type = types.str;
        default = "4G";
        description = ''
          virtio-gpu hostmem: PCI BAR window for mapped host blobs
          (address space, not a RAM reservation).
        '';
      };
    };

    simplex = {
      enable = mkEnableOption "a SimpleX Chat daemon inside each guest (state on the vault share)";
      allowedUsers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "SIMPLEX_ALLOWED_USERS passed to hermes (contactIds or display names).";
      };
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
      iptables -w -C OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
        || iptables -w -A OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm
    '';
    networking.firewall.extraStopCommands = ''
      iptables -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
      iptables -w -D OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
      iptables -w -F hermes-microvm 2>/dev/null || true
      iptables -w -X hermes-microvm 2>/dev/null || true
    '';

    # Venus host side: qemu (user `microvm`) opens the render node and
    # /dev/udmabuf (root-only by default — hand it to the render group).
    # No DeviceAllow needed: neither microvm unit sets a DevicePolicy.
    # Group grants live in the users.users merge below.
    services.udev.extraRules = lib.mkIf cfg.gpu.enable ''
      KERNEL=="udmabuf", GROUP="render", MODE="0660"
    '';

    microvm.vms = lib.mapAttrs' (user: ucfg:
      lib.nameValuePair (vmName user) {
        config = guestConfig user ucfg;
        # default for fully-declarative VMs; listed for greppability
        autostart = true;
      }
    ) cfg.users;

    # Re-mirror the timezone whenever /etc/localtime is swapped.
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

      # State-vault hiding: PrivateMounts + the bind in ExecStartPre mean
      # only virtiofsd sees the hermes state; slave propagation keeps the
      # store/exchange shares receiving host mounts. Deliberately NO "+"
      # prefix — a full-privilege Exec line skips the namespacing options
      # and would leak the mount into the host namespace. (Upstream
      # defines this unit with overrideStrategy=asDropin; these merge.)
      "microvm-virtiofsd@${vmName user}" = {
        serviceConfig = {
          PrivateMounts = true;
          ExecStartPre = [ "${vaultBindScript user}" ];
        };
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

      }))
    ];

    # Share sources must exist before virtiofsd starts; guest/* contents
    # are filled by the provisioning ExecStartPre. The decoys under /run
    # stay empty in the host namespace by design.
    systemd.tmpfiles.rules =
      [
        "d /var/lib/hermes-microvm 0755 root root - -"
        "d /run/hermes-microvm-shares 0755 root root - -"
      ]
      ++ lib.concatLists (lib.mapAttrsToList (user: _: [
        "d ${baseDir user} 0755 root root - -"
        "d ${baseDir user}/ssh 0755 root root - -"
        "d ${baseDir user}/guest 0755 root root - -"
        "d ${baseDir user}/guest/ssh 0755 root root - -"
        "d ${baseDir user}/guest/secrets 0700 root root - -"
        "d ${baseDir user}/state-vault 0700 root root - -"
        "d ${baseDir user}/state-vault/state 0700 ${user} users - -"
        "d ${shareSourceDir user} 0755 root root - -"
        "d ${shareSourceDir user}/state 0700 root root - -"
        "d ${exchangeDir user} 0755 ${user} users - -"
        "d ${guestWorkspace user} 0755 ${user} users - -"
      ]) cfg.users);

    # The per-user gateway socket must exist at boot, before any
    # interactive login.
    users.users = lib.mkMerge [
      (forEachUser (user: ucfg: {
        ${user} = {
          # Pin the host uid: firewall owner-match, guest account, share
          # ownership and port/MAC derivation all assume they agree.
          uid = ucfg.uid;
        } // lib.optionalAttrs ucfg.spacesGateway.enable {
          linger = true;
        };
      }))
      # Venus: render node + udmabuf access for the qemu processes.
      (lib.mkIf cfg.gpu.enable {
        microvm.extraGroups = [ "render" "video" ];
      })
    ];
  };
}
