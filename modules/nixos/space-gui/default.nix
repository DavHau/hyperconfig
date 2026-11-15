/*
  space-gui: GUI apps of a space container (infra-space, a hyper.spaces
  container, ...) on the host user's Wayland session, on demand.

    space-gui <container> <command> [args...]

  run as the host user (`hostUser`; on Dave's desktops
  hyper.daveDesktop.user, ../dave-desktop) from inside the Wayland
  session. It runs ./helper.py as root through sudo (NOPASSWD for wheel
  and that store path only; the helper admits no one but that user), which for the command's lifetime makes a run
  directory /run/space-gui/<container>/<run>/ here, in the container
  /run/space-gui/<run>/ (the container's /run/space-gui is that host
  directory, bound read-only from its start: `machinectl bind` refuses
  containers with their own user namespace, ../spaces/host.nix), with:

  - wayland-0: a new socket handed to the compositor through
    wp_security_context_v1 (sandbox engine "space-gui", app id the
    container's name). The session's own socket never enters the
    container; closing the run retires this one;
  - open.sock: the URL broker. The container's `xdg-open` (a shim first on
    the command's PATH) hands URLs to it; only https URLs on the
    container's `openOrigins` open, in the host user's browser (their
    systemd user manager). An OAuth native sign-in's redirect_uri
    http://127.0.0.1:<port>/... (the app listens on the container's
    loopback, a port of its ephemeral range) gets this host's
    127.0.0.1:<port> forwarded into the container, so the browser's
    redirect reaches the app: one shot, closed once the callback request
    has been answered, after three minutes at the latest.

  The command runs in the container as the space's user, a transient unit
  (`systemd-run -M`), with WAYLAND_DISPLAY at that socket, its own
  XDG_RUNTIME_DIR, the user's HOME, and a private D-Bus session
  (dbus-run-session; no host bus).

  Light/dark: the run follows the host session's preference, dark when it
  cannot be read (./color-scheme.py, ./helper.py's ColorScheme). The helper
  reads org.freedesktop.appearance color-scheme from the session's
  xdg-desktop-portal as the host user (a watcher process on the host
  user's bus, outside the container), and writes it to the run
  directory's `color-scheme` file, again on every change. In the
  container the run's private bus gets, before the command starts, a
  minimal org.freedesktop.portal.Desktop (the command runs as its child)
  that has only the Settings interface and
  only that key, serves the file's value and announces its changes, so
  apps that follow the portal (GTK 4/libadwaita, Qt 6) start in the
  host's scheme and follow it live. Electron (43, the hermes desktop app)
  does not ask the portal: it takes GTK's prefer-dark setting at launch,
  which the run's gtk-3.0/gtk-4.0 settings.ini carries
  (gtk-application-prefer-dark-theme, first on XDG_CONFIG_DIRS; the
  user's own ~/.config overrides it), so it starts in the host's scheme
  and changes with the next launch. The value is also in
  SPACE_GUI_COLOR_SCHEME. Nothing flows from the container to the host:
  the file is written by root, read-only in the guest, and only `dark` or
  `light` from the watcher counts. An app's own persisted theme (e.g.
  hermes-desktop's native-theme.json, set from its settings) still wins.

  What the opening gives a container: one restricted Wayland connection
  point. No X11, no PulseAudio/PipeWire, no host D-Bus, no /run/user, no
  /dev/dri (apps render in software: Electron with --disable-gpu or
  HERMES_DESKTOP_DISABLE_GPU). A client on it can draw its own windows,
  take input while focused, and read and set the clipboard (on paste or
  focus, as any app); the security context keeps it from niri's
  privileged protocols (screencopy, data control, virtual keyboard and
  pointer, input method, foreign toplevel, workspace and output
  management, session lock), so it cannot read other windows, keystrokes
  sent to them, or the screen. The compositor must offer
  wp_security_context_manager_v1 (niri and sway do); the helper refuses
  to run otherwise.

  Tested by the `space-gui` flake check (./test.nix): a headless sway as
  the host user, a container, a Wayland client launched through
  `space-gui`, its security context, and the URL broker.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.spaceGui;

  # The container's xdg-open: hand the URL to the run's broker socket.
  shim = pkgs.writeShellScriptBin "xdg-open" ''
    if [ -z "''${SPACE_GUI_OPEN:-}" ] || [ $# -ne 1 ]; then
      echo "xdg-open (space-gui): usage: xdg-open <https-url>" >&2
      exit 1
    fi
    reply=$(printf '%s' "$1" | ${pkgs.socat}/bin/socat -t 10 - "UNIX-CONNECT:$SPACE_GUI_OPEN")
    [ "$reply" = ok ] || { echo "xdg-open (space-gui): $reply: $1" >&2; exit 1; }
  '';

  dbus = pkgs.dbus;

  # The light/dark preference (./color-scheme.py): `host-watch` as the host
  # user on their session bus, `portal` in the container on the run's bus.
  colorScheme = pkgs.writeShellScript "space-gui-color-scheme" ''
    exec ${pkgs.python3.withPackages (p: [ p.dbus-fast ])}/bin/python3 ${./color-scheme.py} "$@"
  '';

  helperConfig = pkgs.writeText "space-gui.json" (
    builtins.toJSON {
      inherit (cfg) hostUser;
      hostUid = config.users.users.${cfg.hostUser}.uid;
      opener = cfg.opener;
      shim = "${shim}";
      colorScheme = "${colorScheme}";
      dbusRunSession = "${dbus}/bin/dbus-run-session";
      dbusDaemon = "${dbus}/bin/dbus-daemon";
      dbusSessionConf = "${dbus}/share/dbus-1/session.conf";
      containers = lib.mapAttrs (_: c: {
        inherit (c)
          user
          uid
          home
          openOrigins
          ;
      }) cfg.containers;
    }
  );

  helper = pkgs.writeShellScriptBin "space-gui-helper" ''
    export PATH=${
      lib.makeBinPath [
        config.systemd.package
        pkgs.util-linux
        pkgs.socat
        pkgs.coreutils
      ]
    }
    export SPACE_GUI_CONFIG=${helperConfig}
    exec ${pkgs.python3.withPackages (p: [ p.pywayland ])}/bin/python3 ${./helper.py} "$@"
  '';

  launcher = pkgs.writeShellScriptBin "space-gui" ''
    if [ $# -lt 2 ]; then
      echo "usage: space-gui <container> <command> [args...]" >&2
      echo "containers: ${lib.concatStringsSep " " (lib.attrNames cfg.containers)}" >&2
      exit 2
    fi
    if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      echo "space-gui: WAYLAND_DISPLAY is not set (run it from the Wayland session)" >&2
      exit 1
    fi
    exec /run/wrappers/bin/sudo -n ${helper}/bin/space-gui-helper "$1" "''${WAYLAND_DISPLAY##*/}" "''${@:2}"
  '';

  appLauncher =
    name: a:
    pkgs.writeShellScriptBin "space-gui-${name}" ''
      exec ${launcher}/bin/space-gui ${lib.escapeShellArg a.container} ${lib.escapeShellArgs a.command} "$@"
    '';

  appEntry =
    name: a:
    pkgs.makeDesktopItem {
      name = "space-gui-${name}";
      inherit (a) desktopName;
      comment = "${a.desktopName}, running in the ${a.container} container";
      exec = "${appLauncher name a}/bin/space-gui-${name}";
      icon = a.icon;
      categories = [ "Network" ];
    };
in
{
  options.hyper.spaceGui = {
    enable = lib.mkEnableOption "launching GUI apps of space containers on the host user's Wayland session";
    hostUser = lib.mkOption {
      type = lib.types.str;
      example = "dave";
      description = "The desktop user whose Wayland session shows the apps; the only one allowed to run `space-gui`.";
    };
    opener = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.xdg-utils}/bin/xdg-open";
      defaultText = lib.literalExpression ''"''${pkgs.xdg-utils}/bin/xdg-open"'';
      description = "Command run as the host user (in their systemd user manager) to open a brokered URL.";
    };
    containers = lib.mkOption {
      default = { };
      description = "Containers whose GUI apps may show on the session.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              description = "The space's user the apps run as.";
            };
            uid = lib.mkOption {
              type = lib.types.int;
              description = "Its uid in the container, owner of the run directory (here the same number: the bind is idmapped).";
            };
            home = lib.mkOption {
              type = lib.types.str;
              description = "Its home in the guest.";
            };
            openOrigins = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "https://infra-space.example.org" ];
              description = "https origins whose URLs the container's apps may open in the host user's browser.";
            };
          };
        }
      );
    };
    apps = lib.mkOption {
      default = { };
      description = "Launcher entries (`space-gui-<name>` and a desktop entry) for apps in the containers.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            container = lib.mkOption { type = lib.types.str; };
            command = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Command line in the container (store paths: the guest shares the host's store).";
            };
            desktopName = lib.mkOption { type = lib.types.str; };
            icon = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.elem "wheel" config.users.users.${cfg.hostUser}.extraGroups;
        message = "hyper.spaceGui.hostUser (${cfg.hostUser}) must be in wheel: space-gui's sudo rule is for wheel.";
      }
    ]
    ++ lib.mapAttrsToList (name: a: {
      assertion = cfg.containers ? ${a.container};
      message = "hyper.spaceGui.apps.${name}.container (${a.container}) is not in hyper.spaceGui.containers.";
    }) cfg.apps;

    # The run directories' parent, bound into each container from its
    # start (a container start, i.e. restart, when one is added). Read-only
    # there: its sockets connect all the same, and the guest's root
    # cannot swap a run directory for a link before the helper chowns it.
    # Idmapped where the container has its own user namespace, so the run
    # directories' owners (the guest user's uid) are the same inside.
    systemd.tmpfiles.rules = [ "d /run/space-gui 0755 root root -" ]
    ++ lib.mapAttrsToList (name: _: "d /run/space-gui/${name} 0755 root root -") cfg.containers;
    containers = lib.mapAttrs (name: _: {
      extraFlags = [
        "--bind-ro=/run/space-gui/${name}:/run/space-gui${
          lib.optionalString (config.containers.${name}.privateUsers != "no") ":idmap"
        }"
      ];
    }) cfg.containers;

    environment.systemPackages = [
      launcher
    ]
    ++ lib.mapAttrsToList appLauncher cfg.apps
    ++ lib.mapAttrsToList appEntry cfg.apps;

    security.sudo.extraRules = [
      {
        # wheel, not the user: sudo's execWheelOnly (amy) allows no other
        # grant. The helper itself admits the host user only (SUDO_UID).
        groups = [ "wheel" ];
        runAs = "root";
        commands = [
          {
            command = "${helper}/bin/space-gui-helper";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
