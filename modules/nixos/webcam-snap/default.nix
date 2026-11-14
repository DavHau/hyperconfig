# webcam-snap: lets named users (an agent's ssh account) take ONE still
# photo through this machine's webcam, and blank/unblank its screen,
# without putting them in `video` (that would grant live streaming and
# every other v4l device). vit, pointed at the living-room TV, for
# dave-hermes (../../../machines/vit/configuration.nix).
#
#   webcam-snap [WxH] > shot.jpg   one MJPEG frame (default 1920x1080)
#   vit-screen off|on|status       blank the console panel (greeter only)
#
# Both are clients of root-owned sockets in /run/webcam-snap/ (root:
# webcam-snap 0660; group members = `users`). Each connection starts one
# instance (Accept=yes) of a sandboxed service (./server.py):
#   webcam-snap@  user `webcam` (system, in `video`), sees only v4l
#     devices, no network; ffmpeg with ~2 s warm-up for auto-exposure,
#     15 s timeout. One capture at a time (MaxConnections=1: a concurrent
#     call is refused, not queued), otherwise no limit. Photos go to the
#     socket only, never to disk; the journal gets errors and refusals
#     only ("snapshot by <user> failed: ..."), not every shot.
#   vit-screen@   root (TIOCLINUX blank needs CAP_SYS_ADMIN, kept as the
#     only capability); only acts while greetd's VT (tty1, fixed by the
#     NixOS greetd module) is the active one, logind's active session on
#     seat0 is the greeter's, and that VT is in text mode. Never inside a
#     logged-in session or on another console.
# The screen also blanks by itself after `idleBlankMinutes` on the console
# (kernel `consoleblank=`; tuigreet and greetd never touch the blank
# timer, a key press wakes it; graphical sessions are not affected). The
# panel goes dark via DPMS, the lid stays open so the camera sees.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.webcamSnap;
  sockDir = "/run/webcam-snap";
  snapSocket = "${sockDir}/snap.sock";
  screenSocket = "${sockDir}/screen.sock";

  conf = pkgs.writeText "webcam-snap.json" (
    builtins.toJSON {
      inherit (cfg) device defaultSize;
      # greetd's VT: the NixOS module fixes it to VT1 (services.greetd.vt
      # was removed for that reason).
      greeterVt = "tty1";
      ffmpeg = lib.getExe' pkgs.ffmpeg-headless "ffmpeg";
      # The camera's MJPEG modes (v4l2-ctl --list-formats-ext).
      sizes = [
        "1920x1080"
        "1280x720"
        "800x600"
        "640x480"
        "320x240"
      ];
      warmupSeconds = 2;
      timeoutSeconds = 15;
    }
  );

  client = pkgs.writers.writePython3Bin "webcam-snap" { flakeIgnore = [ "E501" ]; } (
    builtins.replaceStrings [ "@snapSocket@" "@screenSocket@" ] [ snapSocket screenSocket ] (
      builtins.readFile ./client.py
    )
  );
  clients = pkgs.runCommand "webcam-snap-clients" { } ''
    mkdir -p $out/bin
    ln -s ${client}/bin/webcam-snap $out/bin/webcam-snap
    ln -s ${client}/bin/webcam-snap $out/bin/vit-screen
  '';

  server = mode: "${lib.getExe pkgs.python3} ${./server.py} ${conf} ${mode}";

  socket = description: path: max: {
    inherit description;
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = path;
      MaxConnections = max;
      Accept = true;
      SocketUser = "root";
      SocketGroup = "webcam-snap";
      SocketMode = "0660";
      DirectoryMode = "0755";
    };
  };

  sandbox = {
    StandardInput = "socket";
    StandardOutput = "socket";
    StandardError = "journal";
    RuntimeMaxSec = 30;
    PrivateNetwork = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    RestrictAddressFamilies = [ "AF_UNIX" ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    InaccessiblePaths = [ "/dev/shm" ];
    LockPersonality = true;
    NoNewPrivileges = true;
    SystemCallArchitectures = "native";
    # ioctl (KDGETMODE/TIOCLINUX for vit-screen, VIDIOC_* for ffmpeg) is in
    # @system-service.
    SystemCallFilter = [ "@system-service" ];
    DevicePolicy = "closed";
    UMask = "0077";
  };
in
{
  options.hyper.webcamSnap = {
    enable = lib.mkEnableOption "one-shot webcam photos and screen blanking for named users";
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users allowed to call webcam-snap and vit-screen (group webcam-snap).";
    };
    device = lib.mkOption {
      type = lib.types.str;
      description = ''
        The colour capture node by a stable path. Prefer /dev/v4l/by-path:
        cameras with an IR sensor on the same USB serial collide in by-id
        (vit's by-id ...-video-index0 points at the IR camera).
      '';
    };
    defaultSize = lib.mkOption {
      type = lib.types.str;
      default = "1920x1080";
    };
    idleBlankMinutes = lib.mkOption {
      type = lib.types.ints.between 0 60;
      default = 5;
      description = "Blank the console (greeter) panel after this many idle minutes; 0 = never.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.webcam-snap.members = cfg.users;
    users.groups.webcam = { };
    users.users.webcam = {
      isSystemUser = true;
      group = "webcam";
      extraGroups = [ "video" ];
    };

    environment.systemPackages = [ clients ];

    # One capture at a time; a second caller is refused, not queued.
    systemd.sockets.webcam-snap = socket "One-shot webcam photo" snapSocket 1;
    systemd.services."webcam-snap@" = {
      description = "One webcam photo";
      serviceConfig = sandbox // {
        ExecStart = server "snap";
        User = "webcam";
        Group = "webcam";
        SupplementaryGroups = [ "video" ];
        DeviceAllow = [ "char-video4linux rw" ];
        CapabilityBoundingSet = "";
        # No PrivateUsers: SO_PEERCRED must see the caller's real uid.
        SystemCallFilter = [
          "@system-service"
          "~@privileged @resources"
        ];
        MemoryDenyWriteExecute = true;
      };
    };

    systemd.sockets.vit-screen = socket "Blank/unblank the console panel" screenSocket 2;
    systemd.services."vit-screen@" = {
      description = "Blank/unblank the console panel";
      serviceConfig = sandbox // {
        ExecStart = server "screen";
        # Only greetd's VT (greeterVt above).
        DeviceAllow = [ "/dev/tty1 rw" ];
        CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
        MemoryDenyWriteExecute = true;
      };
    };

    # Console blank timer (kernel default for every VT; graphical sessions
    # are not affected).
    boot.kernelParams = lib.mkIf (cfg.idleBlankMinutes > 0) [
      "consoleblank=${toString (cfg.idleBlankMinutes * 60)}"
    ];
  };
}
