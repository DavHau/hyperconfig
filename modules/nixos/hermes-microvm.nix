# Hermes Agent (NousResearch) in per-user MicroVMs — microvm.nix, fully
# declarative, qemu + slirp user networking (no host bridge/NAT; coexists
# with NetworkManager).
#
# One VM per configured user ("hermes-<user>"). Inside each guest the
# UPSTREAM hermes NixOS module runs in native mode as a guest account with
# the same name/uid as the host user. The guest gets the host's /nix/store
# read-only, a namespace-hidden virtiofs share for HERMES state (see
# below), an artifact workspace exposed on the host as ~/hermes/workspace,
# and passwordless sudo inside the guest. The guest account's HOME is the
# state dir (upstream convention): artifacts land in the workspace
# (default session cwd), dotfiles/caches in the hidden vault.
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
#
# Isolation between users: ssh keys and dashboard tokens are owner-only
# files, and iptables OUTPUT owner-match rules reject other local users on
# every forwarded loopback port. Residual caveats:
#   - all VMs' qemu processes run as the shared `microvm` user; the
#     loopback allowlist (spaces ports + DNS, REJECT otherwise) keeps
#     guests off arbitrary host loopback services, but one user's guest
#     can still reach ANOTHER user's spaces bridge port;
#   - owner-match gates CONNECTS, not LISTENS: while a VM is down, any
#     local user can squat its free forwarded port. ssh fails closed
#     (pinned host key); the shim/desktop wrappers refuse to talk unless
#     the VM unit is active, but a browser can still be phished into
#     sending the dashboard token to a squatter. Full fix would be a
#     vsock backend behind a root-held socket;
#   - the guest never sees the owner's real home. Its persistence surface
#     is ~/hermes/workspace (owner-auditable) plus the hidden state vault;
#     host dotfile-planting via a shared home is no longer possible.
# All acceptable for now with a single configured user.
#
# HERMES state (/var/lib/hermes in the guest) is a virtiofs share. The
# real data lives in a root-only vault on the host,
#   /var/lib/hermes-microvm/<user>/state-vault/state   (vault 0700 root),
# while the share's `source` points at an EMPTY decoy dir under
# /run/hermes-microvm-shares/<user>/. Only the per-VM virtiofsd unit sees
# the data: it runs with PrivateMounts plus an ExecStartPre bind mount
# vault -> share-source inside its private mount namespace. INVARIANT:
# the host must never open the state sqlite DBs — a host-side reader
# would reintroduce exactly the cross-kernel sqlite coordination that
# virtiofs cannot provide (no remote locks, unsafe WAL mmap). Inspect
# state through the guest (`hermes`/ssh) or via
#   nsenter -m -t "$(systemctl show -p MainPID --value microvm-virtiofsd@hermes-<user>)"
# sqlite safety on virtiofs: WAL needs a MAP_SHARED -shm mapping whose
# FUSE cache invalidation is unreliable, so the guest runs a patched
# hermes package (hermesPackageNoWal below) that forces
# journal_mode=DELETE for every DB family. fcntl/flock locking is
# guest-local and safe: all lockers of a given DB live in one guest
# kernel.
#
# pip: guests get a venv at /var/lib/hermes/.venv with the preinstalled
# scientific stack importable AND `pip install` working — see
# ./hermes-guest-python.nix (shared module, pinned by the
# `hermes-guest-python` flake check).
#
# Hardware acceleration: the host desktop owns the iGPU, so no
# passthrough — instead `gpu.enable` gives every guest Vulkan via QEMU
# Venus (virtio-gpu-gl-pci + egl-headless on the host render node; the
# iGPU is time-shared with the host compositor). Computation is
# otherwise CPU-side: openblas-backed numpy/scipy, CPU torch with
# AVX-512, numba JIT.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.hermes-microvm;

  vmName = user: "hermes-${user}";
  baseDir = user: "/var/lib/hermes-microvm/${user}";
  # Share `source`s for the state vault: empty decoy dirs in the host
  # namespace; the real vault is bind-mounted over them only inside the
  # virtiofsd unit's private mount namespace (see the drop-in below).
  shareSourceDir = user: "/run/hermes-microvm-shares/${user}";

  # Fixed guest paths
  guestStateDir = "/var/lib/hermes";
  guestHostDir = "/run/hermes-host"; # ro virtiofs: ssh keys + secrets
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

    # VM runtime dir (virtiofsd sockets, current-system symlink) — no
    # world access. The hermes state itself lives in the state-vault,
    # hidden from the host; see the virtiofsd drop-in.
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

  # ── Guest hermes package: sqlite WAL disabled ────────────────────────
  # /var/lib/hermes is a virtiofs share now. Guest-local fcntl/flock (the
  # gateway/CLI seam, .dispatch.lock) are fine on rust virtiofsd, but
  # sqlite WAL mode needs a MAP_SHARED mmap of the -shm index whose FUSE
  # page-cache invalidation is not reliable — a corruption risk, not a
  # clean failure: on virtiofs (cache=auto) `PRAGMA journal_mode=WAL`
  # SUCCEEDS, so upstream's WAL->DELETE fallback
  # (hermes_state.apply_wal_with_fallback, which only matches "locking
  # protocol"/"not authorized" errors) never fires, and
  # agent/verification_evidence.py sets WAL with no fallback at all.
  # There is no config/env knob for the journal mode, so the wheel is
  # patched to force rollback-journal (DELETE) deterministically:
  #   - apply_wal_with_fallback() returns "delete" always; that covers
  #     state.db, kanban*.db, projects.db, response_store.db and the
  #     holographic memory store (they all call the helper);
  #   - agent/verification_evidence.py and tools/async_delegation.py
  #     (raw WAL pragmas, no fallback) set journal_mode=DELETE directly.
  # The upstream package is a bin-wrapper around a sealed uv2nix venv,
  # itself a symlink farm over per-wheel store paths — so: copy the farm,
  # embed a patched copy of the hermes wheel, retarget the farm's links,
  # and re-point the wrapper. A build-time grep proves no WAL set-pragma
  # survives anywhere in the wheel.
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
    substituteInPlace "$out/pkg/$sp/agent/verification_evidence.py" \
      --replace-fail 'conn.execute("PRAGMA journal_mode=WAL")' \
                     'conn.execute("PRAGMA journal_mode=DELETE")'
    substituteInPlace "$out/pkg/$sp/tools/async_delegation.py" \
      --replace-fail 'conn.execute("PRAGMA journal_mode=WAL")' \
                     'conn.execute("PRAGMA journal_mode=DELETE")'
    # Stale bytecode would shadow the patched sources.
    rm -f "$out/pkg/$sp/__pycache__/hermes_state."*.pyc \
          "$out/pkg/$sp/agent/__pycache__/verification_evidence."*.pyc \
          "$out/pkg/$sp/tools/__pycache__/async_delegation."*.pyc
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

  # Bind the state vault over the empty share-source dir INSIDE the
  # virtiofsd unit's private mount namespace (PrivateMounts on the
  # drop-in below; all Exec* lines of a unit share one namespace). Every
  # unit start gets a fresh namespace, hence the idempotent re-assertion
  # of the tmpfiles layout before mounting.
  vaultBindScript = user: pkgs.writeShellScript "hermes-vault-bind-${user}" ''
    set -eu
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils util-linux ])}
    install -d -m 0700 -o root -g root ${baseDir user}/state-vault
    install -d -m 0700 -o ${user} -g users ${baseDir user}/state-vault/state
    install -d -m 0755 ${baseDir user}/state-vault/state/simplex
    mkdir -p ${shareSourceDir user}
    install -d -m 0700 -o root -g root ${shareSourceDir user}/state
    mount --bind ${baseDir user}/state-vault/state ${shareSourceDir user}/state
  '';

  # ── Guest NixOS configuration (fully declarative microvm) ────────────
  guestConfig = user: ucfg: { config, lib, pkgs, ... }: {
    imports = [
      inputs.hermes-agent.nixosModules.default
      ./hermes-guest-python.nix
      ./simplex-chat.nix
    ];

    # SimpleX daemon lives INSIDE the guest (no host loopback exposure).
    # Its SQLite state must persist -> bind /var/lib/simplex-chat onto the
    # vault share. Known amber risk: simplex runs its own SQLite (likely
    # WAL) on virtiofs; guest-only access keeps the host out, the residual
    # FUSE-mmap hazard is accepted — worst case is re-pairing contacts.
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
          # Artifact exchange: one flat dir shared by ALL hermes sessions,
          # never GC'd by hermes — cleanup is the owner's manual call.
          # Mounted over the state share (nested). Do not open live SQLite
          # DBs the agent creates here while the VM runs (cross-kernel
          # locking is not coordinated over virtiofs).
          proto = "virtiofs";
          tag = "hermes-workspace";
          source = "/home/${user}/hermes/workspace";
          mountPoint = guestWorkspace;
        }
        {
          proto = "virtiofs";
          tag = "host-config";
          source = "${baseDir user}/guest";
          mountPoint = guestHostDir;
          readOnly = true;
        }
        {
          # HERMES state: virtiofs from the namespace-hidden vault (the
          # source is an empty decoy dir in the host namespace — the
          # virtiofsd unit bind-mounts the real vault over it; see the
          # drop-in). cache stays "auto" (the default): the guest never
          # uses sqlite WAL (hermesPackageNoWal), and exec/MAP_PRIVATE
          # mmaps in .venv and node caches need the page cache. Persists
          # across guest rebuilds; sqlite + lockfile coordination stays
          # guest-local.
          proto = "virtiofs";
          tag = "hermes-state";
          source = "${shareSourceDir user}/state";
          mountPoint = guestStateDir;
        }
      ];
      # Writable store overlay so `nix` works inside the guest.
      writableStoreOverlay = "/nix/.rw-store";

      # Venus (Vulkan-in-guest): qemu renders on the host iGPU's render
      # node via egl-headless; the guest sees a virtio-gpu-gl PCI device
      # with venus+blob. hostmem is a PCI BAR address window for mapped
      # blobs, not a RAM reservation. Appended after the runner's
      # `-nographic` (which only pre-sets display "none"; the later
      # -display wins and the serial console redirection is kept).
      qemu.extraArgs = lib.optionals cfg.gpu.enable [
        "-display" "egl-headless,rendernode=/dev/dri/renderD128"
        "-device" "virtio-gpu-gl-pci,hostmem=${cfg.gpu.hostmem},blob=true,venus=true"
      ];
      # microvm.optimize (default on) swaps in a qemu built with
      # nixosTestRunner=true, which strips SDL -> OpenGL -> virgl ->
      # venus. Disable it when gpu is on; everything else it would have
      # set is pinned explicitly below.
      optimize.enable = !cfg.gpu.enable;
    };

    # Guest-visible microvm.optimize defaults, pinned explicitly so that
    # switching optimize.enable off (gpu) regresses nothing (mirrors
    # microvm.nix nixos-modules/microvm/optimization.nix at the pinned
    # rev; one deliberate divergence: upstream keeps system.switch
    # enabled when sshd + a store share make switching viable — these
    # guests are fully declarative, so it stays off).
    documentation.enable = lib.mkDefault false;
    boot.initrd.systemd.enable = lib.mkDefault true;
    boot.initrd.systemd.tpm2.enable = lib.mkDefault false;
    boot.kernelParams = [ "8250.nr_uarts=1" ];
    boot.swraid.enable = lib.mkDefault false;
    networking.useNetworkd = lib.mkDefault true;
    systemd.network.wait-online.enable = lib.mkDefault false;
    systemd.tpm2.enable = lib.mkDefault false;
    system.switch.enable = lib.mkDefault false;

    # Venus guest side: virtio-gpu DRM device + the mesa Vulkan ICD
    # (hardware.graphics pulls in mesa, which ships the virtio "venus"
    # driver). microvm.nix blacklists drm whenever its own graphics
    # option is off — take the blacklist over minus drm (rest reproduced
    # from nixos-modules/microvm/system.nix at the pinned rev).
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

    # Timezone tracks the host: /etc/localtime points into the live host
    # share; the host path unit re-mirrors it on change. New processes see
    # the new zone immediately; already-running daemons keep their cached
    # TZ (normal glibc behavior, same as on the host).
    time.timeZone = null;
    systemd.tmpfiles.rules = [
      "L+ /etc/localtime - - - - ${guestHostDir}/tz/localtime"
    ];

    # Same name/uid as on the host so shared-dir ownership maps 1:1. HOME
    # is the state dir — matching the upstream gateway service (it sets
    # HOME=stateDir), so services, ssh logins and sudo shells agree on one
    # home. Dotfiles/caches land in the (hidden) vault; user-facing output
    # lands in the workspace (default cwd, host-visible at
    # ~/hermes/workspace via MESSAGING_CWD/WorkingDirectory upstream).
    users.users.${user} = {
      isNormalUser = true;
      uid = ucfg.uid;
      group = "users";
      home = guestStateDir;
      createHome = false;
      # render/video: Vulkan on the virtio-gpu render node (Venus).
      extraGroups = [ "wheel" ] ++ lib.optionals cfg.gpu.enable [ "render" "video" ];
    };
    # Self-modification parity with the old container (sudo NOPASSWD).
    security.sudo.wheelNeedsPassword = false;

    services.hermes-agent = {
      enable = true;
      # WAL-free build: state.db & friends live on virtiofs (see header).
      package = hermesPackageNoWal;
      user = user;
      group = "users";
      createUser = false;
      stateDir = guestStateDir;
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
      unitConfig.RequiresMountsFor = [ guestStateDir guestWorkspace ];
      # venv first so python/pip resolve to the writable interpreter.
      # NOTE: systemd `path` string entries get /bin appended — pass the
      # venv ROOT, not its bin dir (".venv/bin" rendered as ".venv/bin/bin"
      # and silently dropped the venv from the unit's PATH).
      path = [ config.services.hermes-python.venv ];
      # pip-installed manylinux extension modules (.so) are loaded by the
      # nix-built interpreter, so their NEEDED libs resolve via
      # LD_LIBRARY_PATH — nix-ld doesn't apply to dlopen.
      environment.LD_LIBRARY_PATH = config.services.hermes-python.wheelLibraryPath;
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
      # The upstream unit only allows stateDir+workspace; guestWorkspace is
      # under stateDir, so no extra ReadWritePaths are needed.
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
      unitConfig.RequiresMountsFor = [ guestStateDir guestWorkspace guestHostDir ];
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

    environment.systemPackages = [ pkgs.socat ]
      # vulkaninfo/vkcube for smoke-testing venus
      ++ lib.optionals cfg.gpu.enable [ pkgs.vulkan-tools ];
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
    # the remote command, shell-quoted. Deliberately NOT WAYLAND_DISPLAY:
    # the host clipboard is never bridged into the VM; without the variable
    # hermes's clipboard path stays disabled and paste degrades to
    # "No image found in clipboard".
    env_exports=""
    for v in COLORTERM LANG LC_ALL; do
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
  '') cfg.users) + ''
    # Guest -> host loopback allowlist: everything a guest sends to slirp's
    # 10.0.2.2 egresses here as uid microvm. The per-user spaces-bridge
    # RETURNs above are the only sanctioned services; DNS stays open for
    # slirp's resolver forwarding; the rest of the host's loopback is
    # rejected (it used to be a wildcard).
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

    # Venus host side: qemu (user `microvm`) opens the iGPU render node
    # and /dev/udmabuf (guest blob mappings). /dev/udmabuf is root-only
    # by default — hand it to the render group. Neither microvm@ nor
    # microvm-virtiofsd@ sets a DevicePolicy upstream, so no DeviceAllow
    # lines are needed. (The group grants live in the users.users merge
    # at the bottom of this file.)
    services.udev.extraRules = lib.mkIf cfg.gpu.enable ''
      KERNEL=="udmabuf", GROUP="render", MODE="0660"
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

      # State-vault hiding: virtiofsd (and ONLY virtiofsd) sees the
      # hermes state. PrivateMounts gives the unit a private mount
      # namespace with slave propagation (the /nix/store and /home shares
      # served by this same unit keep receiving host mounts); the
      # ExecStartPre bind-mounts the vault over the empty share-source
      # dir inside that namespace. Deliberately NO "+" prefix: a
      # full-privilege Exec line skips the namespacing options and would
      # leak the mount into the host namespace. (Upstream defines this
      # per-VM unit with overrideStrategy=asDropin; these settings merge
      # into the same drop-in.)
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
    # are filled by the provisioning ExecStartPre. The state vault is a
    # 0700 root door with the user-owned data dir inside (guest uid ==
    # host uid, virtiofsd maps 1:1); the share-source decoys under /run
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
        "d /home/${user}/hermes 0755 ${user} users - -"
        "d /home/${user}/hermes/workspace 0755 ${user} users - -"
      ]) cfg.users);

    # The per-user gateway socket must exist at boot, before any
    # interactive login.
    users.users = lib.mkMerge [
      (forEachUser (user: ucfg: {
        ${user} = {
          # Pin the host uid to the configured one: firewall owner-match,
          # guest account, home-share ownership and port/MAC derivation all
          # assume they agree. A drifted auto-allocated uid would authorize
          # the wrong account silently.
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
