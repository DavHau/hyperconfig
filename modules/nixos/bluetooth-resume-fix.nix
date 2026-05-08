{ pkgs, ... }:
# Workaround for Intel AX210 (USB id 8087:0032) Bluetooth controller:
# the chip frequently fails to reinitialize after suspend — the adapter
# disappears or stays powered-off until btusb is reloaded.
#
# A oneshot service `wantedBy` + `after` the sleep targets activates
# once those targets deactivate, i.e. on resume.
#
# Refs:
#   https://github.com/pop-os/cosmic-epoch/issues/2527
#   https://discourse.nixos.org/t/bluetooth-stops-working-after-resume-from-suspend/63758
{
  systemd.services.bluetooth-resume-fix = {
    description = "Reload btusb after resume (AX210 workaround)";
    wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "bluetooth-resume-fix" ''
        set -eu
        ${pkgs.kmod}/bin/modprobe -r btusb || true
        ${pkgs.kmod}/bin/modprobe btusb
      '';
    };
  };
}
