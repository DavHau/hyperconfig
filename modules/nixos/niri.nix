{pkgs, lib, ...}:
let
  ollamaToggle = pkgs.writeShellScript "ollama-toggle" ''
    config="$HOME/.config/fish-ai.ini"
    if ${pkgs.gnugrep}/bin/grep -q "server = http://localhost" "$config"; then
      ${pkgs.gnused}/bin/sed -i 's|server = http://localhost:11434/v1|server = http://bam.d:11434/v1|' "$config"
    else
      ${pkgs.gnused}/bin/sed -i 's|server = http://bam.d:11434/v1|server = http://localhost:11434/v1|' "$config"
    fi
    # Swap which model line is active (expects exactly two model lines: one commented, one not)
    ${pkgs.gnused}/bin/sed -i -e 's/^model = /TEMP_MODEL = /' -e 's/^; model = /model = /' -e 's/^TEMP_MODEL = /; model = /' "$config"
    pkill -RTMIN+10 waybar
  '';

  ollamaStatus = pkgs.writeShellScript "ollama-status" ''
    config="$HOME/.config/fish-ai.ini"
    if ${pkgs.gnugrep}/bin/grep -q "server = http://localhost" "$config"; then
      echo '{"text":"LOCAL","tooltip":"Ollama: localhost","alt":"local","class":"local"}'
    else
      echo '{"text":"BAM","tooltip":"Ollama: bam.d","alt":"remote","class":"remote"}'
    fi
  '';
in
{
  programs.niri.enable = true;
  # programs.waybar.enable = true;

  environment.systemPackages = with pkgs; [
    fuzzel
    light
    mako
    networkmanagerapplet
    swayidle
    swaylock
    xwayland-satellite
  ];

  environment.variables = {
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    CLUTTER_BACKEND = "wayland";
    ECORE_EVAS_ENGINE = "wayland_egl";
    ELM_ENGINE = "wayland_egl";
    GDK_BACKEND = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
    NIXOS_OZONE_WL = "1";
    QT_QPA_PLATFORM = "wayland-egl";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
    QT_WAYLAND_FORCE_DPI = "physical";
    SDL_VIDEODRIVER = "wayland";
    XDG_SESSION_TYPE = "wayland";
  };

  home-manager.users.grmpf = {
    xdg.configFile."niri/config.kdl".source = ./niri-config.kdl;

    services.network-manager-applet.enable = true;

    services.swayidle = {
      enable = true;
      events = [
        { event = "before-sleep"; command = "${pkgs.swaylock}/bin/swaylock -f -c 000000"; }
      ];
      timeouts = [
        { timeout = 300; command = "${pkgs.swaylock}/bin/swaylock -f -c 000000"; }
        { timeout = 600; command = "niri msg action power-off-monitors"; }
      ];
    };

    programs.waybar = {
      enable = true;
      style = ./waybar-style.css;
      settings.mainBar = {
        height = 20;
        spacing = 4;
        modules-left = [ "niri/workspaces" ];
        modules-center = [ "niri/window" ];
        modules-right = [
          "custom/ollama"
          "idle_inhibitor"
          "pulseaudio"
          "network"
          "power-profiles-daemon"
          "cpu"
          "memory"
          "temperature"
          "backlight"
          "custom/brightness-20"
          "custom/brightness-40"
          "custom/brightness-60"
          "custom/brightness-80"
          "custom/brightness-100"
          "keyboard-state"
          "battery"
          "battery#bat2"
          "clock"
          "tray"
          "custom/power"
        ];
        keyboard-state = {
          numlock = true;
          capslock = true;
          format = "{name} {icon}";
          format-icons = {
            locked = "";
            unlocked = "";
          };
        };
        idle_inhibitor = {
          format = "{icon}";
          format-icons = {
            activated = "";
            deactivated = "";
          };
        };
        tray = {
          spacing = 10;
        };
        clock = {
          tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
          format-alt = "{:%Y-%m-%d}";
        };
        cpu = {
          format = "{usage}% ";
          tooltip = false;
        };
        memory = {
          format = "{}% ";
        };
        temperature = {
          critical-threshold = 80;
          format = "{temperatureC}°C {icon}";
          format-icons = [ "" "" "" ];
        };
        backlight = {
          format = "{percent}% {icon}";
          format-icons = [ "" "" "" "" "" "" "" "" "" ];
        };
        battery = {
          states = {
            warning = 30;
            critical = 15;
          };
          format = "{capacity}% {icon}";
          format-full = "{capacity}% {icon}";
          format-charging = "{capacity}% {icon}";
          format-plugged = "{capacity}% ";
          format-alt = "{time} {icon}";
          format-icons = [ "" "" "" "" "" ];
        };
        "battery#bat2" = {
          bat = "BAT2";
        };
        "power-profiles-daemon" = {
          format = "{icon}";
          tooltip-format = "Power profile: {profile}\nDriver: {driver}";
          tooltip = true;
          format-icons = {
            default = "";
            performance = "";
            balanced = "";
            power-saver = "";
          };
        };
        network = {
          format-wifi = "{essid} ({signalStrength}%) ";
          format-ethernet = "{ipaddr}/{cidr} ";
          tooltip-format = "{ifname} via {gwaddr} ";
          format-linked = "{ifname} (No IP) ";
          format-disconnected = "Disconnected ⚠";
          format-alt = "{ifname}: {ipaddr}/{cidr}";
        };
        pulseaudio = {
          format = "{volume}% {icon} {format_source}";
          format-bluetooth = "{volume}% {icon} {format_source}";
          format-bluetooth-muted = " {icon} {format_source}";
          format-muted = " {format_source}";
          format-source = "{volume}% ";
          format-source-muted = "";
          format-icons = {
            headphone = "";
            hands-free = "";
            headset = "";
            phone = "";
            portable = "";
            car = "";
            default = [ "" "" "" ];
          };
          on-click = "pavucontrol";
        };
        "custom/brightness-20" = {
          format = "🌑";
          tooltip = false;
          on-click = "${pkgs.brightnessctl}/bin/brightnessctl set 20%";
        };
        "custom/brightness-40" = {
          format = "🌒";
          tooltip = false;
          on-click = "${pkgs.brightnessctl}/bin/brightnessctl set 40%";
        };
        "custom/brightness-60" = {
          format = "🌓";
          tooltip = false;
          on-click = "${pkgs.brightnessctl}/bin/brightnessctl set 60%";
        };
        "custom/brightness-80" = {
          format = "🌔";
          tooltip = false;
          on-click = "${pkgs.brightnessctl}/bin/brightnessctl set 80%";
        };
        "custom/brightness-100" = {
          format = "🌕";
          tooltip = false;
          on-click = "${pkgs.brightnessctl}/bin/brightnessctl set 100%";
        };
        "custom/ollama" = {
          format = "{icon}";
          return-type = "json";
          format-icons = {
            local = "🏠";
            remote = "🖥️";
          };
          exec = "${ollamaStatus}";
          on-click = "${ollamaToggle}";
          interval = 60;
          signal = 10;
        };
        "custom/power" = {
          format = "⏻ ";
          tooltip = false;
          menu = "on-click";
          menu-file = "${pkgs.waybar.src}/resources/custom_modules/power_menu.xml";
          menu-actions = {
            shutdown = "shutdown";
            reboot = "reboot";
            suspend = "systemctl suspend";
            hibernate = "systemctl hibernate";
          };
        };
      };
    };
  };

  security.pam.services.swaylock = {};
  security.polkit.enable = true;
}
