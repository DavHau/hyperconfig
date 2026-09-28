# Show the NixOS snowflake on the LCD of a Thermalright AIO pump head
# (USB 0416:5302 "USBDISPLAY", firmware 4.07, PM=51 Frozen Warframe), and
# spin it while the CPU as a whole is more than half busy.
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

  # The arms alternate two blues, so the logo only repeats every 120
  # degrees (shape alone: 60): 40 frames 3 degrees apart make a seamless
  # loop. Rendered at build time: the runtime streamer needs no image
  # libraries. One file, frames back to back, frame 0 upright.
  frames =
    pkgs.runCommand "cooler-lcd-nixos-frames"
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
        python3 - logo.png $out <<'EOF'
        import struct, sys
        from PIL import Image

        logo = Image.open(sys.argv[1]).convert("RGBA")
        header = bytearray(512)
        header[0:4] = bytes([0xDA, 0xDB, 0xDC, 0xDD])
        header[4] = 2  # version
        header[6] = 1  # command: picture
        header[8:12] = struct.pack("<HH", 240, 320)
        header[12] = 2  # RGB565
        header[22:26] = struct.pack("<I", 240 * 320 * 2)
        header[29] = 8

        with open(sys.argv[2], "wb") as out:
            for step in range(40):
                # Negative: Pillow turns counter-clockwise, spin clockwise.
                turned = logo.rotate(-3 * step, Image.BICUBIC)
                turned = turned.resize((200, 200), Image.LANCZOS)
                canvas = Image.new("RGB", (240, 320))
                canvas.paste(turned, (20, 60), turned)
                rgb = canvas.tobytes()
                out.write(header)
                out.write(b"".join(
                    struct.pack("<H", (r >> 3) << 11 | (g >> 2) << 5 | b >> 3)
                    for r, g, b in zip(rgb[0::3], rgb[1::3], rgb[2::3])
                ))
        EOF
      '';

  # hidraw takes a leading report-ID byte per write (0: the report
  # descriptor declares no IDs); each write is one 512-byte output report
  # and blocks until the panel took it, which paces a frame at ~50 ms.
  # A write error (device gone) ends the process; systemd restarts it.
  stream = pkgs.writers.writePython3 "cooler-lcd-stream" { } ''
    import os
    import sys
    import time

    FRAME = 512 + 240 * 320 * 2

    data = open(sys.argv[2], "rb").read()
    frames = [
        [b"\x00" + data[f + o:f + o + 512] for o in range(0, FRAME, 512)]
        for f in range(0, len(data), FRAME)
    ]


    def cpu_times():
        # Aggregate "cpu" line: every core. Fields 8+ (guest) are already
        # counted in user/nice.
        with open("/proc/stat") as f:
            ticks = [int(x) for x in f.readline().split()[1:9]]
        return sum(ticks) - ticks[3] - ticks[4], sum(ticks)


    fd = os.open(sys.argv[1], os.O_WRONLY)
    busy, total = cpu_times()
    sampled = time.monotonic()
    spinning = False
    index = 0
    while True:
        now = time.monotonic()
        if now - sampled >= 1:
            b, t = cpu_times()
            spinning = t > total and (b - busy) / (t - total) > 0.5
            busy, total, sampled = b, t, now
        # Stopping finishes the turn back to upright rather than freezing
        # mid-angle.
        if spinning or index:
            index = (index + 1) % len(frames)
        for report in frames[index]:
            os.write(fd, report)
        # Idle, the unchanged frame is only a keepalive.
        time.sleep(0.02 if spinning or index else 0.5)
  '';
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
