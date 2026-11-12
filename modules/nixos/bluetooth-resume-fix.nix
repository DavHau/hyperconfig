{ pkgs, ... }:
# Workaround for Intel AX210 (USB id 8087:0032) Bluetooth controller:
# the chip frequently fails to reinitialize after suspend — the adapter
# disappears or stays powered-off until btusb is reloaded.
#
# A oneshot service `wantedBy` + `after` the sleep targets activates
# once those targets deactivate, i.e. on resume.
#
# Reloading btusb re-creates hci0 under a running bluetoothd. Its
# AutoEnable powers the new adapter, but the desktop (noctalia) starts
# reconnecting every paired device at that moment; bluez then sometimes
# powers the adapter down again and stays Busy, so the shell's toggle
# fails and nothing reconnects (2026-11-12: "Unexpected NULL
# btd_adv_monitor_manager object upon power down", then setPowered: Busy).
# So after the reload, wait for hci0 and make sure it ends up powered,
# restarting bluetoothd once if it does not.
#
# Refs:
#   https://github.com/pop-os/cosmic-epoch/issues/2527
#   https://discourse.nixos.org/t/bluetooth-stops-working-after-resume-from-suspend/63758
let
  bctl = "${pkgs.bluez}/bin/bluetoothctl";
in
{
  systemd.services.bluetooth-resume-fix = {
    description = "Reload btusb after resume (AX210 workaround)";
    wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "3min";
      ExecStart = pkgs.writeShellScript "bluetooth-resume-fix" ''
        set -u
        ${pkgs.kmod}/bin/modprobe -r btusb || true
        ${pkgs.kmod}/bin/modprobe btusb

        powered() { ${bctl} show 2>/dev/null | grep -q 'Powered: yes'; }
        settle() {
          # hci0 back, then powered (AutoEnable or by us) and staying so
          for _ in $(seq 1 20); do
            ${bctl} show >/dev/null 2>&1 && break
            sleep 1
          done
          for _ in $(seq 1 10); do
            if powered; then
              sleep 15   # the desktop's reconnect burst is when it fell over
              powered && return 0
            fi
            timeout 10 ${bctl} power on >/dev/null 2>&1 || true
            sleep 2
          done
          return 1
        }

        settle && exit 0
        echo "hci0 not powered after btusb reload; restarting bluetoothd" >&2
        ${pkgs.systemd}/bin/systemctl restart bluetooth.service
        settle || { echo "hci0 still not powered" >&2; exit 1; }
      '';
    };
  };
}
