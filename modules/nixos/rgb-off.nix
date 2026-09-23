# Keep every RGB LED of the machine dark. The LEDs forget their state on
# a power cycle and come back in their rainbow default, so this re-applies
# "off" at every boot and after every resume.
#
# - DRAM (ENE SMBus controllers, e.g. Kingston Fury): OpenRGB, mode Off.
#   Needs the AMD SMBus (i2c-piix4) and i2c-dev.
# - Colorful motherboard ARGB headers (USB 2f4c:1013): not supported by
#   OpenRGB, so a black direct frame is written to the FF01 HID interface.
#   Protocol: https://github.com/czw63/colorful-2f4c-openrgb
#   (REVERSE_ENGINEERING.md). The controller latches the last frame.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.rgbOff;

  # Ten 20-LED data reports of zeros, end-of-data, commit. Each write() must
  # be exactly one 65-byte report (leading 0x00 = report ID, stripped by
  # usbhid), so this is not a shell one-liner.
  colorfulArgbOff = pkgs.writers.writePython3 "colorful-argb-off" { } ''
    import os
    import sys

    fd = os.open(sys.argv[1], os.O_WRONLY)


    def report(*head):
        data = bytes([0x00, 0x01, 0x00, *head])
        os.write(fd, data + bytes(65 - len(data)))


    for window in range(10):
        report(0x88, window)
    report(0x88, 0xFF)
    report(0xAA, 0x00)
    os.close(fd)
  '';
in
{
  options.hyper.rgbOff.colorfulArgb = lib.mkEnableOption ''
    switching off the ARGB headers of a Colorful motherboard (USB 2f4c:1013),
    where fans and water blocks plug in'';

  config = lib.mkMerge [
    {
      boot.kernelModules = [
        "i2c-dev"
        "i2c-piix4"
      ];

      systemd.services.rgb-off = {
        description = "Switch off DRAM RGB LEDs";
        after = [ "systemd-modules-load.service" ];
        wantedBy = [
          "multi-user.target"
          "post-resume.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "rgb-off";
          # Devices OpenRGB finds but that have no Off mode (e.g. an MSI
          # Mystic Light header on bam) print an error and are skipped.
          ExecStart = lib.escapeShellArgs [
            (lib.getExe pkgs.openrgb)
            "--noautoconnect"
            "--config"
            "/var/lib/rgb-off"
            "--mode"
            "off"
          ];
        };
      };
    }

    (lib.mkIf cfg.colorfulArgb {
      # Interface 1 is the FF01 lighting collection; interface 0 (FF00) takes
      # writes but lights nothing. udev starts the service whenever the
      # device appears, so boot ordering and USB re-enumeration are covered.
      # ENV, not ATTRS: vendor and interface number sit on different parents.
      services.udev.extraRules = ''
        SUBSYSTEM=="hidraw", IMPORT{builtin}="usb_id", ENV{ID_VENDOR_ID}=="2f4c", ENV{ID_MODEL_ID}=="1013", ENV{ID_USB_INTERFACE_NUM}=="01", SYMLINK+="colorful-argb", TAG+="systemd", ENV{SYSTEMD_WANTS}+="colorful-argb-off.service"
      '';

      systemd.services.colorful-argb-off = {
        description = "Switch off Colorful motherboard ARGB headers";
        requires = [ "dev-colorful\\x2dargb.device" ];
        after = [ "dev-colorful\\x2dargb.device" ];
        wantedBy = [ "post-resume.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${colorfulArgbOff} /dev/colorful-argb";
        };
      };
    })
  ];
}
