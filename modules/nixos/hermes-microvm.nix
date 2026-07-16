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
#   - Web dashboard: guest `hermes dashboard` on 0.0.0.0:9119, forwarded to
#     127.0.0.1:<dashboardPort>. Non-loopback binds require an auth
#     provider upstream; a per-user basic-auth password is generated on the
#     host (`hermes-vm-info` prints URL + credentials).
#   - spaces MCP: guest socat -> slirp host alias 10.0.2.2:<spacesPort> ->
#     host socat (running as the owner) -> the per-user gateway socket in
#     /run/user/<uid>.
#   - voice mode (per-user opt-in `audio.enable`): the hermes package
#     already ships the `voice` group (sounddevice/numpy/faster-whisper);
#     what NixOS/VMs lack is libportaudio discovery and a sound card. The
#     guest gets LD_LIBRARY_PATH with portaudio (+ ld/gcc for ctypes
#     find_library) and a virtio-sound device whose qemu `pa` backend
#     connects to a host socket proxy (systemd-socket-proxyd running as
#     the owner) in front of the user's pipewire-pulse socket.
#
# Isolation between users: ssh keys and dashboard passwords are owner-only
# files, and iptables OUTPUT owner-match rules reject other local users on
# every forwarded loopback port. Residual caveat: all VMs' qemu processes
# run as the shared `microvm` user, so one user's *guest* could reach
# another user's spaces bridge port (and host loopback services like the
# simplex daemon) — acceptable for now with a single configured user.
#
# pip: guests get a venv at /var/lib/hermes/.venv created from a nixpkgs
# python-with-packages interpreter with --system-site-packages, so the
# preinstalled scientific stack is importable AND `pip install` works
# (writable venv + nix-ld for manylinux wheels; see
# ../../../nixos-example/devShells/phi3 for the LD_LIBRARY_PATH variant
# this replaces).
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
  dashboardGuestPort = 9119;
  # slirp's alias for the host's loopback
  slirpHostAlias = "10.0.2.2";
  # Host-side proxy socket in front of the owner's pipewire-pulse socket;
  # mode 0660 root:kvm so only qemu (microvm user) can connect.
  audioProxySocket = user: "/run/hermes-microvm-audio/${user}.sock";

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
    # provides the `ld` that ctypes.util.find_library needs to resolve
    # libraries from LD_LIBRARY_PATH (portaudio for voice mode)
    gcc gnumake pkg-config binutils
    # documents / media / research helpers
    pandoc poppler-utils ffmpeg imagemagick sqlite yt-dlp w3m alsa-utils
    # runtimes & package managers agents reach for
    nodejs uv
  ];

  # Shared libs for `pip install`ed manylinux wheels (nix-ld).
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
    portaudio
    alsa-lib
  ];

  # Root ExecStartPre of microvm@hermes-<user>: per-user keys, dashboard
  # credentials, guest secret env files, VM state dir lockdown, and a
  # bounded wait for the owner's spaces gateway socket.
  provisionScript = user: ucfg: pkgs.writeShellScript "hermes-microvm-provision-${user}" ''
    set -eu
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils gawk openssh openssl ])}
    base=${baseDir user}
    install -d -m 0755 "$base" "$base/ssh" "$base/guest" "$base/guest/ssh"
    install -d -m 0700 "$base/guest/secrets"

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

    # dashboard basic-auth credentials (password readable by the owner)
    if [ ! -f "$base/dashboard-password" ]; then
      (umask 277; openssl rand -base64 24 | tr -d '\n' > "$base/dashboard-password")
    fi
    chown ${user} "$base/dashboard-password"
    chmod 0400 "$base/dashboard-password"
    if [ ! -f "$base/dashboard-secret" ]; then
      (umask 277; openssl rand -hex 32 | tr -d '\n' > "$base/dashboard-secret")
    fi

    # secrets handed to the guest (root-only inside the ro mount)
    umask 077
    {
      printf 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=%s\n' ${user}
      printf 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=%s\n' "$(cat "$base/dashboard-password")"
      printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' "$(cat "$base/dashboard-secret")"
    } > "$base/guest/secrets/dashboard.env"
    : > "$base/guest/secrets/hermes.env.tmp"
    ${lib.concatMapStrings (f: ''
      if [ -f ${f} ]; then
        cat ${f} >> "$base/guest/secrets/hermes.env.tmp"
        printf '\n' >> "$base/guest/secrets/hermes.env.tmp"
      else
        echo "hermes-microvm: missing environment file ${f}" >&2
      fi
    '') ucfg.environmentFiles}
    mv "$base/guest/secrets/hermes.env.tmp" "$base/guest/secrets/hermes.env"

    # VM state dir holds the hermes state volume image — no world access
    if [ -d /var/lib/microvms/${vmName user} ]; then
      chmod 0750 /var/lib/microvms/${vmName user}
    fi

    ${lib.optionalString ucfg.spacesGateway.enable ''
      # Bounded wait for the owner's spaces gateway socket (linger brings
      # the user manager up at boot). Non-fatal: MCP reconnects later.
      for _i in $(seq 1 60); do
        [ -S ${ucfg.spacesGateway.socket} ] && break
        sleep 1
      done
    ''}
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

      # Voice mode: virtio sound card, backed by the owner's PipeWire via
      # the host-side pulse proxy socket. The default qemu is minimized
      # (`optimize.enable` pipes ANY qemu.package through
      # nixosTestRunner=true, the "for-vm-tests" build) and ships no audio
      # backends — qemu then dies instantly on `-audiodev pa`. So for
      # audio VMs use stock qemu_kvm and turn the qemu minimization off;
      # the guest-side optimize defaults are pinned explicitly below.
      optimize.enable = lib.mkIf ucfg.audio.enable false;
      qemu.package = lib.mkIf ucfg.audio.enable pkgs.qemu_kvm;
      qemu.extraArgs = lib.optionals ucfg.audio.enable [
        "-audiodev"
        "pa,id=hermes-snd,server=unix:${audioProxySocket user}"
        "-device"
        "virtio-sound-pci,audiodev=hermes-snd"
      ];
    };

    # Keep the guest-visible microvm.optimize defaults stable whether or
    # not audio disabled the optimize module (values identical to
    # microvm.nix nixos-modules/microvm/optimization.nix).
    documentation.enable = lib.mkDefault false;
    boot.initrd.systemd.enable = lib.mkDefault true;
    boot.kernelParams = [ "8250.nr_uarts=1" ];
    boot.swraid.enable = lib.mkDefault false;
    networking.useNetworkd = lib.mkDefault true;
    systemd.network.wait-online.enable = lib.mkDefault false;
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

    # Same name/uid as on the host so the shared home keeps ownership.
    users.users.${user} = {
      isNormalUser = true;
      uid = ucfg.uid;
      group = "users";
      home = "/home/${user}";
      createHome = false;
      extraGroups = [ "wheel" ] ++ lib.optional ucfg.audio.enable "audio";
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
      # venv first so python/pip resolve to the writable interpreter
      path = [ "${guestVenv}/bin" ];
      # sounddevice (voice mode) resolves libportaudio via LD_LIBRARY_PATH
      environment.LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.portaudio ];
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
    # gateway by upstream design; shares state via HERMES_HOME. Non-loopback
    # bind requires an auth provider -> basic auth from the host-generated
    # per-user credentials.
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
        # streaming TTS uses sounddevice too
        LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.portaudio ];
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
          "0.0.0.0"
          "--port"
          (toString dashboardGuestPort)
        ];
        WorkingDirectory = guestWorkspace;
        Restart = "always";
        RestartSec = 5;
        UMask = "0007";
      };
    };

    # manylinux wheels from pip need a link-loader + common shared libs
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = nixLdLibraries;

    environment.systemPackages = [ pkgs.socat ];
    # interactive ssh/TUI shells also get the writable venv first, and
    # libportaudio for voice mode (sounddevice ships no linux binaries)
    environment.extraInit = ''
      export PATH="${guestVenv}/bin:$PATH"
      export LD_LIBRARY_PATH="${lib.makeLibraryPath [ pkgs.portaudio ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${userCaseArms}
    *)
      echo "hermes: no hermes microvm configured for user $u" >&2
      exit 1
      ;;
    esac
    base="/var/lib/hermes-microvm/$u"
    tty_flag=""
    if [ -t 0 ] && [ -t 1 ]; then tty_flag="-t"; fi
    # ssh only carries TERM; the old docker-exec routing also passed
    # COLORTERM/LANG/LC_ALL (TUI colors + UTF-8 glyphs). Embed them into
    # the remote command, shell-quoted.
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
    base="/var/lib/hermes-microvm/$u"
    echo "VM:            microvm@hermes-$u.service"
    echo "CLI/TUI:       hermes (routed via ssh, port $ssh_port)"
    echo "Dashboard:     http://127.0.0.1:$dashboard_port/"
    echo "  username:    $u"
    echo "  password:    $(${pkgs.coreutils}/bin/cat "$base/dashboard-password" 2>/dev/null || echo "<unreadable — not your VM?>")"
  '';

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
          audio = {
            enable = mkEnableOption "a virtio sound card backed by the user's PipeWire (hermes voice mode)";
            pulseSocket = mkOption {
              type = types.str;
              default = "/run/user/${toString config.uid}/pulse/native";
              description = "The user's pipewire-pulse socket on the host.";
            };
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
    environment.systemPackages = [ hermesShim hermesInfo ];

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

    systemd.services = forEachUser (user: ucfg: {
      "microvm@${vmName user}" = {
        # "+" = run with full privileges (the unit itself runs as `microvm`)
        serviceConfig.ExecStartPre = [ "+${provisionScript user ucfg}" ];
      } // lib.optionalAttrs (ucfg.spacesGateway.enable || ucfg.audio.enable) {
        # both the spaces gateway socket and pipewire-pulse live in the
        # owner's user session
        after = [ "user@${toString ucfg.uid}.service" ];
        wants = [ "user@${toString ucfg.uid}.service" ];
      };

      # voice mode: socket-activated proxy (running as the owner) in front
      # of the user's pipewire-pulse socket; qemu's `pa` audiodev connects
      # to the 0660 root:kvm proxy socket.
      "hermes-audio-proxy-${user}" = lib.mkIf ucfg.audio.enable {
        description = "PipeWire-Pulse proxy for ${vmName user} audio";
        after = [ "user@${toString ucfg.uid}.service" ];
        wants = [ "user@${toString ucfg.uid}.service" ];
        serviceConfig = {
          User = user;
          ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${ucfg.audio.pulseSocket}";
          PrivateTmp = true;
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
    });

    # Activation sockets for the audio proxies. 0660 root:kvm: only qemu
    # (the `microvm` user) reaches the owner's audio (same cross-VM
    # caveat as the spaces bridge — see header).
    systemd.sockets = forEachUser (user: ucfg: {
      "hermes-audio-proxy-${user}" = lib.mkIf ucfg.audio.enable {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ (audioProxySocket user) ];
        socketConfig = {
          SocketUser = "root";
          SocketGroup = "kvm";
          SocketMode = "0660";
        };
      };
    });

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

    # The per-user gateway/pipewire sockets must exist at boot, before any
    # interactive login.
    users.users = forEachUser (user: ucfg:
      lib.optionalAttrs (ucfg.spacesGateway.enable || ucfg.audio.enable) {
        ${user}.linger = true;
      });
  };
}
