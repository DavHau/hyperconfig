# Guest NixOS configuration (fully declarative microvm), one per user —
# applied by ./vms.nix. The upstream hermes NixOS module runs natively in
# each guest; see ./default.nix for the architecture overview and the
# state-vault WAL invariant.
{ lib, pkgs, inputs, hlib, cfg }:
let
  inherit (hlib)
    vmName macFor credNames exchangeDir guestWorkspace guestStateDir
    guestHostDir dashboardGuestPort dashboardGuestBackendPort slirpHostAlias;

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

  # Upstream package unmodified: sqlite WAL on virtiofs (cache=auto) is
  # safe here — virtiofsd never sets FOPEN_DIRECT_IO under cache=auto,
  # so the WAL -shm MAP_SHARED mmap is page-cache backed and coherent
  # for all guest processes, and POSIX locks are handled guest-locally
  # (virtiofsd doesn't negotiate FUSE_POSIX_LOCKS). The "WAL doesn't
  # work on network filesystems" hazard is separate page caches, i.e.
  # host<->guest — excluded by the header invariant.
  hermesPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
user: ucfg: { config, lib, pkgs, ... }: {
  imports = [
    inputs.hermes-agent.nixosModules.default
    ./guest-python.nix
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
    # Host->guest channels ride vsock (CID = uid): nothing listens on
    # the host's loopback on a dead VM's behalf.
    vsock.cid = ucfg.uid;
    # Secrets as fw_cfg credentials — never on a share, never on a
    # command line. STRING paths (a Nix path literal would copy the
    # secret into the store): the deterministic credentials dir of the
    # host unit that execs this qemu.
    credentialFiles = lib.genAttrs (credNames ucfg)
      (name: "/run/credentials/microvm@${vmName user}.service/${name}");
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
        source = "${hlib.baseDir user}/guest";
        mountPoint = guestHostDir;
        readOnly = true;
      }
      {
        # HERMES state from the root-only vault. cache stays "auto":
        # WAL needs the coherent page-cache mmap, and exec/MAP_PRIVATE
        # mmaps in .venv need the page cache.
        proto = "virtiofs";
        tag = "hermes-state";
        source = "${hlib.baseDir user}/state-vault/state";
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
  boot.kernelModules = [ "vmw_vsock_virtio_transport" ]
    ++ lib.optionals cfg.gpu.enable [ "virtio_gpu" ];
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

  # sshd is socket-activated so one instance set serves TCP :22
  # (guest-internal) and vsock :22 (the host `hermes` shim).
  services.openssh = {
    enable = true;
    startWhenNeeded = true;
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
  systemd.sockets.sshd.listenStreams = [ "vsock::22" ];

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
    package = hermesPackage;
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
      touch "$env_file"
      ${pkgs.gnused}/bin/sed -i -E \
        '/^(export[[:space:]]+)?(PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|NIX_PYTHONPATH)=/d' \
        "$env_file"
      # Rewrite the credential-managed secret block: hermes loads .env
      # with override=True (beats process env) and ssh CLI sessions
      # read it directly, so credentials must land here. Strip-then-
      # append keeps rotated or removed keys from going stale.
      ${pkgs.gnused}/bin/sed -i \
        '/^# BEGIN hermes-microvm credentials$/,/^# END hermes-microvm credentials$/d' \
        "$env_file"
      if [ -n "''${CREDENTIALS_DIRECTORY:-}" ]; then
        {
          echo "# BEGIN hermes-microvm credentials"
          for f in "$CREDENTIALS_DIRECTORY"/*; do
            [ -f "$f" ] || continue
            printf '%s=%s\n' "$(basename "$f")" "$(cat "$f")"
          done
          echo "# END hermes-microvm credentials"
        } >> "$env_file"
      fi
    '';
    # Upstream hardcodes HOME=stateDir in the unit env; force the
    # exchange dir so ~ is the same path in guest and host.
    environment.HOME = lib.mkForce (exchangeDir user);
    # Upstream's ProtectSystem=strict allows only stateDir+workspace;
    # HOME sits one level above the workspace, so writes like ~/.cache
    # need the exchange dir writable too.
    serviceConfig.ReadWritePaths = [ (exchangeDir user) ];
    # Secrets arrive as unit credentials ($CREDENTIALS_DIRECTORY is set
    # up before ExecStartPre and readable by the unit user).
    serviceConfig.ImportCredential = lib.attrNames ucfg.secretEnv;
  };

  # Web dashboard (SPA + JSON-RPC/WS backend); separate process by
  # upstream design, shares state via HERMES_HOME. Loopback bind:
  # non-loopback engages the cookie-only auth gate the desktop's static
  # remote token cannot pass.
  systemd.services.hermes-dashboard = {
    description = "Hermes Agent web dashboard";
    wantedBy = [ "multi-user.target" ];
    # after hermes-agent: ordering only (not Requires) — its preStart
    # refreshes the .env this process reads at startup.
    after = [ "network-online.target" "hermes-python-venv.service" "hermes-agent.service" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = [ guestStateDir (exchangeDir user) ];
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
      ImportCredential = "dashboard_token";
      # Token as env var: read from the unit's credentials dir at start.
      ExecStart = pkgs.writeShellScript "hermes-dashboard-start" ''
        HERMES_DASHBOARD_SESSION_TOKEN=$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/dashboard_token")
        export HERMES_DASHBOARD_SESSION_TOKEN
        exec ${config.services.hermes-agent.package}/bin/hermes dashboard \
          --no-open --host 127.0.0.1 --port ${toString dashboardGuestBackendPort}
      '';
      WorkingDirectory = guestWorkspace user;
      Restart = "always";
      RestartSec = 5;
      UMask = "0007";
    };
  };

  # Bridge vsock :9119 (host socket-activated forward) to the loopback
  # dashboard. Every forwarded client thus looks "loopback" to
  # upstream; the real boundary is the host's iptables owner match.
  systemd.services.hermes-dashboard-proxy = {
    description = "Hermes dashboard guest-side vsock proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "hermes-dashboard.service" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.socat}/bin/socat"
        "VSOCK-LISTEN:${toString dashboardGuestPort},fork"
        "TCP:127.0.0.1:${toString dashboardGuestBackendPort}"
      ];
      Restart = "always";
      RestartSec = 5;
    };
  };

  environment.systemPackages = [ pkgs.socat ]
    # vulkaninfo/vkcube for smoke-testing venus
    ++ lib.optionals cfg.gpu.enable [ pkgs.vulkan-tools ];
}
