# Show the NixOS snowflake on the LCD of a Thermalright AIO pump head
# (USB 0416:5302 "USBDISPLAY", firmware 4.07, PM=51 Frozen Warframe),
# spinning at a speed proportional to the CPU use of all cores together.
# Every 20 s it shows "I <red heart emoji> Joy" for 1 s.
#
# Protocol as in https://github.com/NoNameOnFile/trlcd_libusb (the format
# of https://github.com/Lexonight1/thermalright-trcc-linux, a 20-byte header
# glued to the pixels, is accepted but never displayed on this unit): one
# 512-byte header report, then 240x320 little-endian RGB565 as 300 reports
# of 512 bytes. No init handshake is needed. Measured on som: the panel
# falls back to its stock image seconds after frames stop, so frames are
# streamed continuously.
#
# At night the panel goes fully dark: there is no backlight command, but
# disabling its USB port (hyper.coolerLcd.usbPort) cuts it off entirely,
# measured on som. Re-enabling the port re-enumerates the panel and udev
# starts the streamer again.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.coolerLcd;

  # Asia/Bangkok, the room the machine sits in, whatever time.timeZone is.
  zone = "Asia/Bangkok";
  offHour = 22;
  onHour = 7;

  # One idempotent "apply the state the clock asks for", run by the timer
  # at both edges and at boot (the port comes up enabled), so a missed edge
  # or a reboot at night converges.
  schedule = pkgs.writeShellApplication {
    name = "cooler-lcd-schedule";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      port=/sys/bus/usb/devices/${cfg.usbPort}/disable
      hour=$(TZ=${zone} date +%-H)
      if (( hour >= ${toString offHour} || hour < ${toString onHour} )); then
        want=1
      else
        want=0
      fi
      if [[ $(cat "$port") != "$want" ]]; then
        echo "$want" > "$port"
        echo "port ${cfg.usbPort} disable=$want"
      fi
    '';
  };

  # Rendered at build time (./render.py): the runtime streamer needs no
  # image libraries.
  frames =
    pkgs.runCommand "cooler-lcd-frames"
      {
        nativeBuildInputs = [
          pkgs.librsvg
          (pkgs.python3.withPackages (p: [ p.pillow ]))
        ];
      }
      ''
        rsvg-convert -w 800 -h 800 -a \
          ${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg \
          -o logo.png
        mkdir $out
        python3 ${./render.py} logo.png \
          ${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf \
          ${pkgs.noto-fonts-color-emoji}/share/fonts/noto/NotoColorEmoji.ttf \
          $out
      '';

  stream = pkgs.writers.writePython3 "cooler-lcd-stream" { } (builtins.readFile ./stream.py);
in
{
  options.hyper.coolerLcd.usbPort = lib.mkOption {
    type = lib.types.str;
    example = "1-0:1.0/usb1-port8";
    description = ''
      Hub port of the LCD under /sys/bus/usb/devices, switched off at
      night. `readlink -f /sys/bus/usb/devices/<dev>/port` names it.
    '';
  };

  config = {
    # udev starts the service whenever the panel appears (boot, replug,
    # re-enumeration); BindsTo stops it when the panel goes away.
    services.udev.extraRules = ''
      SUBSYSTEM=="hidraw", IMPORT{builtin}="usb_id", ENV{ID_VENDOR_ID}=="0416", ENV{ID_MODEL_ID}=="5302", SYMLINK+="cooler-lcd", TAG+="systemd", ENV{SYSTEMD_WANTS}+="cooler-lcd.service"
    '';

    systemd.services.cooler-lcd = {
      description = "NixOS logo on the AIO cooler LCD, spinning under CPU load";
      bindsTo = [ "dev-cooler\\x2dlcd.device" ];
      after = [ "dev-cooler\\x2dlcd.device" ];
      serviceConfig = {
        ExecStart = "${stream} /dev/cooler-lcd ${frames}";
        Restart = "always";
        RestartSec = 2;
      };
    };

    systemd.services.cooler-lcd-schedule = {
      description = "Cooler LCD off ${toString offHour}:00-${toString onHour}:00 ${zone}";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe schedule;
      };
    };
    systemd.timers.cooler-lcd-schedule = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = [
        "*-*-* ${toString offHour}:00:00 ${zone}"
        "*-*-* ${toString onHour}:00:00 ${zone}"
      ];
    };
  };
}
