# Host-side wiring per user: provisioning drop-ins on the microvm@ and
# virtiofsd units (ssh keys, state-vault, credentials), the root-held
# dashboard-forward and spaces-bridge socket units, the timezone mirror,
# tmpfiles and the per-VM qemu identities.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.hermes-microvm;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib) vmName vmUser baseDir exchangeDir guestWorkspace dashboardGuestPort;
  scripts = import ./scripts.nix { inherit lib pkgs hlib cfg; };
  inherit (scripts) provisionScript tzSyncScript sharePrepScript;

  # Assembled under static top-level option keys — a config-dependent
  # mkMerge list at the config root makes option-key resolution depend on
  # cfg.users (infinite recursion).
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.users);
in
{
  config = lib.mkIf cfg.enable {
    # vhost-vsock for the ssh/dashboard channels (device node is kvm-group
    # via systemd's default udev rules; per-VM users are in kvm).
    boot.kernelModules = [ "vhost_vsock" ];

    # Venus host side: qemu (per-VM uid, in render/video) opens the render
    # node and /dev/udmabuf (root-only by default — hand it to the render
    # group). No DeviceAllow needed: no microvm unit sets a DevicePolicy.
    services.udev.extraRules = lib.mkIf cfg.gpu.enable ''
      KERNEL=="udmabuf", GROUP="render", MODE="0660"
    '';

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
        # "+" = run with full privileges (the unit runs as the per-VM uid)
        serviceConfig.ExecStartPre = [ "+${provisionScript user ucfg}" ];
        # Override upstream's shared `microvm` user: one uid per VM keeps
        # guests distinguishable to netfilter and file permissions.
        serviceConfig.User = vmUser user;
        # Per-secret systemd credentials: qemu (the unit's main process)
        # reads them from $CREDENTIALS_DIRECTORY; the guest config maps
        # them through microvm.credentialFiles (fw_cfg). Strict: a
        # missing source file fails the VM start (fail-loud after a
        # forgotten `clan vars generate`).
        serviceConfig.LoadCredential =
          lib.mapAttrsToList (name: path: "${name}:${path}") ucfg.secretEnv
          ++ [ "dashboard_token:${baseDir user}/desktop-token" ];
      } // lib.optionalAttrs ucfg.spacesGateway.enable {
        # the spaces gateway socket lives in the owner's user session
        after = [ "user@${toString ucfg.uid}.service" ];
        wants = [ "user@${toString ucfg.uid}.service" ];
      };

      # Re-assert share sources at every start. (Upstream defines this
      # unit with overrideStrategy=asDropin; these merge.)
      "microvm-virtiofsd@${vmName user}" = {
        serviceConfig.ExecStartPre = [ "${sharePrepScript user}" ];
      };

      # Per-connection dashboard forward into the guest over vsock (no
      # slirp hostfwd; the root-held socket unit outlives the VM).
      "hermes-dashboard-fwd-${user}@" = {
        description = "dashboard vsock forward for ${vmName user}";
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.socat}/bin/socat STDIO VSOCK-CONNECT:${toString ucfg.uid}:${toString dashboardGuestPort}";
          StandardInput = "socket";
        };
      };

      # spaces gateway bridge: guest socat -> 10.0.2.2:<port> -> socket
      # unit -> this instance (as the owner, who alone may open the 0700
      # user socket).
      "hermes-spaces-bridge-${user}@" = lib.mkIf ucfg.spacesGateway.enable {
        description = "spaces gateway bridge for ${vmName user}";
        serviceConfig = {
          User = user;
          ExecStart = "${pkgs.socat}/bin/socat STDIO UNIX-CONNECT:${ucfg.spacesGateway.socket}";
          StandardInput = "socket";
        };
      };

      }))
    ];

    # Loopback listeners are bound by root at boot and never released —
    # no squat window while a VM is down. Owner-match still gates connects.
    systemd.sockets = forEachUser (user: ucfg: {
      "hermes-dashboard-fwd-${user}" = {
        description = "dashboard forward socket for ${vmName user}";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "127.0.0.1:${toString ucfg.dashboardPort}" ];
        socketConfig.Accept = true;
      };
      "hermes-spaces-bridge-${user}" = lib.mkIf ucfg.spacesGateway.enable {
        description = "spaces bridge socket for ${vmName user}";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "127.0.0.1:${toString ucfg.spacesPort}" ];
        socketConfig.Accept = true;
      };
    });

    # Share sources must exist before virtiofsd starts; guest/* contents
    # are filled by the provisioning ExecStartPre.
    systemd.tmpfiles.rules =
      [
        "d /var/lib/hermes-microvm 0755 root root - -"
      ]
      ++ lib.concatLists (lib.mapAttrsToList (user: _: [
        "d ${baseDir user} 0755 root root - -"
        "d ${baseDir user}/ssh 0755 root root - -"
        "d ${baseDir user}/guest 0755 root root - -"
        "d ${baseDir user}/guest/ssh 0755 root root - -"
        "d ${baseDir user}/state-vault 0700 root root - -"
        "d ${baseDir user}/state-vault/state 0700 ${user} users - -"
        "d ${exchangeDir user} 0755 ${user} users - -"
        "d ${guestWorkspace user} 0755 ${user} users - -"
      ]) cfg.users);

    # The per-user gateway socket must exist at boot, before any
    # interactive login.
    users.users = forEachUser (user: ucfg: {
      ${user} = {
        # Pin the host uid: firewall owner-match, guest account, share
        # ownership and port/MAC/CID derivation all assume they agree.
        uid = ucfg.uid;
      } // lib.optionalAttrs ucfg.spacesGateway.enable {
        linger = true;
      };
      # qemu identity: kvm for /dev/kvm, vhost-vsock and the virtiofsd
      # sockets (upstream --socket-group=kvm); render/video for Venus.
      ${vmUser user} = {
        isSystemUser = true;
        group = "kvm";
        extraGroups = lib.optionals cfg.gpu.enable [ "render" "video" ];
      };
    });
  };
}
