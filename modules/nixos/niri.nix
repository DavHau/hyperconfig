{ config, pkgs, lib, inputs, ... }:
let
  reload-noctalia = pkgs.writeShellScript "reload-noctalia" ''
    ${pkgs.procps}/bin/pkill -f 'quickshell' || true
    for _ in $(seq 1 50); do
      ${pkgs.procps}/bin/pgrep -f 'quickshell' >/dev/null || break
      sleep 0.1
    done
    exec noctalia-shell
  '';

  niriEvaluated = inputs.wrappers.wrapperModules.niri.apply {
    inherit pkgs;
    settings = {
      input = {
        keyboard = {
          xkb = {
            layout = "us";
            variant = "altgr-intl";
            options = "eurosign:e";
          };
          numlock = null;
        };
        touchpad = {
          tap = null;
          dwt = null;
          dwtp = null;
          drag = true;
          drag-lock = null;
          natural-scroll = null;
        };
      } // config.niri.inputSettings;

      # layout = {
      #   gaps = 8;
      #   center-focused-column = "never";
      #   preset-column-widths = [
      #     { proportion = 0.33333; }
      #     { proportion = 0.5; }
      #     { proportion = 0.66667; }
      #   ];
      #   default-column-width = { proportion = 0.5; };
      #   focus-ring = {
      #     width = 4;
      #     active-color = "#7fc8ff";
      #     inactive-color = "#505050";
      #   };
      #   border = {
      #     off = null;
      #     width = 4;
      #     active-color = "#ffc87f";
      #     inactive-color = "#505050";
      #     urgent-color = "#9b0000";
      #   };
      #   shadow = {
      #     softness = 30;
      #     spread = 5;
      #     offset = { x = 0; y = 5; _keys = true; };
      #     color = "#0007";
      #   };
      # };

      spawn-at-startup = [ "noctalia-shell" ];

      screenshot-path = "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png";

      window-rules = [
        {
          matches = [{ app-id = "firefox"; title = "^Picture-in-Picture$"; }];
          open-floating = true;
        }
        {
          # Noctalia: rounded corners for all windows
          geometry-corner-radius = 20;
          clip-to-geometry = true;
        }
      ];

      debug = {
        # Required for noctalia notification actions and window activation.
        honor-xdg-activation-with-invalid-serial = null;
      };

      layer-rules = [
        {
          # Noctalia: blurred overview wallpaper on backdrop
          matches = [{ namespace = "^noctalia-overview*"; }];
          place-within-backdrop = true;
        }
      ];

      binds = {
        "Mod+Shift+Slash" = { show-hotkey-overlay = null; };

        "Mod+T" = {
          spawn = "alacritty";
          _attrs = { hotkey-overlay-title = "Open a Terminal: alacritty"; };
        };
        "Mod+D" = {
          spawn = "fuzzel";
          _attrs = { hotkey-overlay-title = "Run an Application: fuzzel"; };
        };
        "Ctrl+Alt+L" = {
          spawn = "swaylock";
          _attrs = { hotkey-overlay-title = "Lock the Screen: swaylock"; };
        };

        # Volume keys
        "XF86AudioRaiseVolume" = {
          spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+" ];
          _attrs = { allow-when-locked = true; };
        };
        "XF86AudioLowerVolume" = {
          spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-" ];
          _attrs = { allow-when-locked = true; };
        };
        "XF86AudioMute" = {
          spawn = [ "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle" ];
          _attrs = { allow-when-locked = true; };
        };
        "XF86AudioMicMute" = {
          spawn = [ "wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle" ];
          _attrs = { allow-when-locked = true; };
        };

        # Overview
        "Mod+O" = {
          toggle-overview = null;
          _attrs = { repeat = false; };
        };

        "Mod+Q" = { close-window = null; };

        # Focus
        "Mod+Left"  = { focus-column-left = null; };
        "Mod+Down"  = { focus-window-down = null; };
        "Mod+Up"    = { focus-window-up = null; };
        "Mod+Right" = { focus-column-right = null; };
        "Mod+H"     = { focus-column-left = null; };
        "Mod+J"     = { focus-window-down = null; };
        "Mod+K"     = { focus-window-up = null; };
        "Mod+L"     = { focus-column-right = null; };

        # Move
        "Mod+Shift+Left"  = { move-column-left = null; };
        "Mod+Shift+Down"  = { move-window-down = null; };
        "Mod+Shift+Up"    = { move-window-up = null; };
        "Mod+Shift+Right" = { move-column-right = null; };
        "Mod+Shift+H"     = { move-column-left = null; };
        "Mod+Shift+J"     = { move-window-down = null; };
        "Mod+Shift+K"     = { move-window-up = null; };
        "Mod+Shift+L"     = { move-column-right = null; };

        "Mod+Home"      = { focus-column-first = null; };
        "Mod+End"       = { focus-column-last = null; };
        "Mod+Ctrl+Home" = { move-column-to-first = null; };
        "Mod+Ctrl+End"  = { move-column-to-last = null; };

        # Move to monitor
        "Mod+Shift+Ctrl+Left"  = { move-column-to-monitor-left = null; };
        "Mod+Shift+Ctrl+Down"  = { move-column-to-monitor-down = null; };
        "Mod+Shift+Ctrl+Up"    = { move-column-to-monitor-up = null; };
        "Mod+Shift+Ctrl+Right" = { move-column-to-monitor-right = null; };
        "Mod+Shift+Ctrl+H"     = { move-column-to-monitor-left = null; };
        "Mod+Shift+Ctrl+J"     = { move-column-to-monitor-down = null; };
        "Mod+Shift+Ctrl+K"     = { move-column-to-monitor-up = null; };
        "Mod+Shift+Ctrl+L"     = { move-column-to-monitor-right = null; };

        # Workspaces
        "Mod+Page_Down" = { focus-workspace-down = null; };
        "Mod+Page_Up"   = { focus-workspace-up = null; };
        "Mod+U"         = { focus-workspace-down = null; };
        "Mod+I"         = { focus-workspace-up = null; };
        "Mod+Ctrl+Down" = { move-column-to-workspace-down = null; };
        "Mod+Ctrl+Up"   = { move-column-to-workspace-up = null; };
        "Mod+Ctrl+U"    = { move-column-to-workspace-down = null; };
        "Mod+Ctrl+I"    = { move-column-to-workspace-up = null; };

        "Mod+Shift+Page_Down" = { move-workspace-down = null; };
        "Mod+Shift+Page_Up"   = { move-workspace-up = null; };
        "Mod+Shift+U"         = { move-workspace-down = null; };
        "Mod+Shift+I"         = { move-workspace-up = null; };

        # Mouse wheel workspace switching
        "Mod+WheelScrollDown"      = { focus-workspace-down = null; _attrs = { cooldown-ms = 150; }; };
        "Mod+WheelScrollUp"        = { focus-workspace-up = null; _attrs = { cooldown-ms = 150; }; };
        "Mod+Ctrl+WheelScrollDown" = { move-column-to-workspace-down = null; _attrs = { cooldown-ms = 150; }; };
        "Mod+Ctrl+WheelScrollUp"   = { move-column-to-workspace-up = null; _attrs = { cooldown-ms = 150; }; };

        "Mod+WheelScrollRight"      = { focus-column-right = null; };
        "Mod+WheelScrollLeft"       = { focus-column-left = null; };
        "Mod+Ctrl+WheelScrollRight" = { move-column-right = null; };
        "Mod+Ctrl+WheelScrollLeft"  = { move-column-left = null; };

        "Mod+Shift+WheelScrollDown"      = { focus-column-right = null; };
        "Mod+Shift+WheelScrollUp"        = { focus-column-left = null; };
        "Mod+Ctrl+Shift+WheelScrollDown" = { move-column-right = null; };
        "Mod+Ctrl+Shift+WheelScrollUp"   = { move-column-left = null; };

        # Workspace by index
        "Mod+1" = { focus-workspace = 1; };
        "Mod+2" = { focus-workspace = 2; };
        "Mod+3" = { focus-workspace = 3; };
        "Mod+4" = { focus-workspace = 4; };
        "Mod+5" = { focus-workspace = 5; };
        "Mod+6" = { focus-workspace = 6; };
        "Mod+7" = { focus-workspace = 7; };
        "Mod+8" = { focus-workspace = 8; };
        "Mod+9" = { focus-workspace = 9; };
        "Mod+Ctrl+1" = { move-column-to-workspace = 1; };
        "Mod+Ctrl+2" = { move-column-to-workspace = 2; };
        "Mod+Ctrl+3" = { move-column-to-workspace = 3; };
        "Mod+Ctrl+4" = { move-column-to-workspace = 4; };
        "Mod+Ctrl+5" = { move-column-to-workspace = 5; };
        "Mod+Ctrl+6" = { move-column-to-workspace = 6; };
        "Mod+Ctrl+7" = { move-column-to-workspace = 7; };
        "Mod+Ctrl+8" = { move-column-to-workspace = 8; };
        "Mod+Ctrl+9" = { move-column-to-workspace = 9; };

        # Column/window management
        "Mod+BracketLeft"  = { consume-or-expel-window-left = null; };
        "Mod+BracketRight" = { consume-or-expel-window-right = null; };
        "Mod+Comma"  = { consume-window-into-column = null; };
        "Mod+Period" = { expel-window-from-column = null; };

        "Mod+R"       = { switch-preset-column-width = null; };
        "Mod+Shift+R" = { switch-preset-window-height = null; };
        "Mod+Ctrl+R"  = { reset-window-height = null; };
        "Mod+F"       = { maximize-column = null; };
        "Mod+Shift+F" = { fullscreen-window = null; };
        "Mod+Ctrl+F"  = { expand-column-to-available-width = null; };
        "Mod+C"       = { center-column = null; };
        "Mod+Ctrl+C"  = { center-visible-columns = null; };

        # Width/height adjustments
        "Mod+Minus" = { set-column-width = "-10%"; };
        "Mod+Equal" = { set-column-width = "+10%"; };
        "Mod+Shift+Minus" = { set-window-height = "-10%"; };
        "Mod+Shift+Equal" = { set-window-height = "+10%"; };

        # Floating/tabbed
        "Mod+V"       = { toggle-window-floating = null; };
        "Mod+Shift+V" = { switch-focus-between-floating-and-tiling = null; };
        "Mod+W"       = { toggle-column-tabbed-display = null; };

        # Screenshots
        "Print"      = { screenshot = null; };
        "Ctrl+Print" = { screenshot-screen = null; };
        "Alt+Print"  = { screenshot-window = null; };

        # Session
        "Mod+Escape" = {
          toggle-keyboard-shortcuts-inhibit = null;
          _attrs = { allow-inhibiting = false; };
        };
        "Mod+Shift+E"    = { quit = null; };
        "Ctrl+Alt+Delete" = { quit = null; };
        "Mod+Shift+P"    = { power-off-monitors = null; };

        # Reload noctalia
        "Mod+Shift+N" = {
          spawn = "${reload-noctalia}";
          _attrs = { hotkey-overlay-title = "Reload Noctalia"; };
        };

        # Brightness
        "XF86MonBrightnessDown" = { spawn = [ "brightnessctl" "set" "5%-" "-e" ]; };
        "XF86MonBrightnessUp"   = { spawn = [ "brightnessctl" "set" "5%+" "-e" ]; };

        # Voice-to-text (voxtype toggle: press to start/stop recording)
        "Mod+Space" = {
          spawn = [ "voxtype" "record" "toggle" ];
          _attrs = { hotkey-overlay-title = "Voice to Text: voxtype"; };
        };
      };

      extraConfig = config.niri.extraConfig;
    };
  };
in
{
  options.niri.extraConfig = lib.mkOption {
    type = lib.types.lines;
    default = ''
      include optional=true "~/.config/niri/displays.kdl"
    '';
    description = "Extra KDL config appended to the niri configuration.";
  };

  options.niri.inputSettings = lib.mkOption {
    type = lib.types.attrs;
    default = {};
    description = "Extra input settings merged into the niri input block.";
  };

  config = {
    programs.niri.enable = true;
    # On `nixos-rebuild switch`, NixOS's switch-to-configuration would
    # normally restart niri.service whenever its [Service] section
    # changes (i.e. on every config tweak, since ExecStartPre/ExecReload
    # embed the per-build kdl path). Setting `reloadIfChanged = true`
    # emits `X-ReloadIfChanged=true` on the unit, which switch reads and
    # converts every "needs restart" verdict into a `systemctl --user
    # reload niri.service` -- running our ExecReload (rewrites mutable
    # runtime config + sends `niri msg action load-config-file`) without
    # killing the live session.
    programs.niri.package = niriEvaluated.wrapper;
    systemd.packages = [ niriEvaluated.outputs.systemd-user ];

    environment.systemPackages = with pkgs; [
      fuzzel
      mako
      swaylock
      xwayland-satellite
    ];

    environment.variables = {
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      NIXOS_OZONE_WL = "1";
      # CLUTTER_BACKEND = "wayland";
      # ECORE_EVAS_ENGINE = "wayland_egl";
      # ELM_ENGINE = "wayland_egl";
      # GDK_BACKEND = "wayland";
      # MOZ_ENABLE_WAYLAND = "1";
      # QT_QPA_PLATFORM = "wayland";
      # QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
      # QT_WAYLAND_FORCE_DPI = "physical";
      # SDL_VIDEODRIVER = "wayland";
      # XDG_SESSION_TYPE = "wayland";
    };

    security.pam.services.swaylock = {};
    security.polkit.enable = true;

    # Battery indicator (noctalia Battery widget needs upower D-Bus)
    services.upower.enable = true;
  };
}
