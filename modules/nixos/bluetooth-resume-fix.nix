{ pkgs, ... }:
# Workaround for Intel AX210 (USB id 8087:0032) Bluetooth controller:
# the chip frequently fails to reinitialize after suspend — the adapter
# disappears or stays powered-off until btusb is reloaded.
#
# A oneshot service `wantedBy` + `after` the sleep targets activates
# once those targets deactivate, i.e. on resume.
#
# Reconnecting after the reload: only what was connected before sleep.
# The desktop shell (noctalia) used to call Device.Connect on EVERY trusted
# device whenever the adapter powered on: it paged absent headsets one by
# one (5 s page timeout each, serialised by the controller) and aborted the
# LE mouse's own reconnect ("le-connection-abort-by-local"), so the mouse
# came back ~35-45 s after resume (journals of 2026-11-10/12/17). Noctalia
# >= 5.5 only does that when opted in ([bluetooth].connect_when_enabled,
# default false; see ./noctalia). Now:
# - LE HID (mouse, joystick): bluez puts bonded HOG devices on the kernel's
#   auto-connect list when hci0 comes back; they reconnect by themselves as
#   soon as they advertise. Never Device.Connect them here (that aborts the
#   pending auto-connect).
# - Classic audio (headsets): bluez's reconnect-on-resume state lives on the
#   adapter's device objects, which the btusb reload destroys. So
#   bluetooth-presuspend records the devices connected before sleep, and
#   after resume this connects those (never absent ones), once each, after
#   an LE mouse had up to 15 s to come back first.
# If hci0 does not end up powered, bluetoothd is restarted once (2026-11-12:
# "Unexpected NULL btd_adv_monitor_manager object upon power down", then
# setPowered: Busy, during noctalia's reconnect burst).
#
# Measurement, one journal line per resume (unit bluetooth-resume-fix):
# "first BT HID input N s after adapter ready" or "no BT HID input ...".
#
# Refs:
#   https://github.com/pop-os/cosmic-epoch/issues/2527
#   https://discourse.nixos.org/t/bluetooth-stops-working-after-resume-from-suspend/63758
let
  bctl = "${pkgs.bluez}/bin/bluetoothctl";
  stateFile = "/run/bluetooth-resume-fix/connected";
  sleepTargets = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
in
{
  # Before sleeping: which devices are connected, and are they LE HID (HOG)?
  systemd.services.bluetooth-presuspend = {
    description = "Record connected Bluetooth devices before sleep";
    wantedBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "20s";
      RuntimeDirectory = "bluetooth-resume-fix";
      RuntimeDirectoryPreserve = true;
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      ExecStart = pkgs.writeShellScript "bluetooth-presuspend" ''
        set -u
        out=${stateFile}
        : > "$out.tmp"
        macs=$(timeout 5 ${bctl} devices Connected 2>/dev/null \
          | ${pkgs.gawk}/bin/awk '$1 == "Device" { print $2 }')
        for mac in $macs; do
          [[ $mac =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || continue
          info=$(timeout 5 ${bctl} info "$mac" 2>/dev/null) || continue
          kind=classic
          # 0x1812 = HID over GATT (LE HID)
          grep -q '00001812-0000-1000-8000-00805f9b34fb' <<<"$info" && kind=lehid
          echo "$mac $kind" >> "$out.tmp"
        done
        mv "$out.tmp" "$out"
        echo "connected before sleep: $(tr '\n' ' ' < "$out")"
      '';
    };
  };

  systemd.services.bluetooth-resume-fix = {
    description = "Reload btusb after resume (AX210 workaround)";
    wantedBy = sleepTargets;
    after = sleepTargets;
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "4min";
      ExecStart = pkgs.writeShellScript "bluetooth-resume-fix" ''
        set -u
        shopt -s nullglob
        state=${stateFile}
        # BT HID devices (bus 0005) before the reload; a reconnect gets a new
        # name (uhid numbers are never reused)
        old=" "
        for d in /sys/bus/hid/devices/0005:*; do old+="''${d##*/} "; done
        ${pkgs.kmod}/bin/modprobe -r btusb || true
        ${pkgs.kmod}/bin/modprobe btusb

        powered() { timeout 5 ${bctl} show 2>/dev/null | grep -q 'Powered: yes'; }
        up() {
          # hci0 back, then powered (AutoEnable or by us)
          for _ in $(seq 1 20); do
            timeout 5 ${bctl} show >/dev/null 2>&1 && break
            sleep 1
          done
          for _ in $(seq 1 10); do
            powered && return 0
            timeout 10 ${bctl} power on >/dev/null 2>&1 || true
            sleep 2
          done
          return 1
        }

        restarted=0
        if ! up; then
          restarted=1
          echo "hci0 not powered after btusb reload; restarting bluetoothd" >&2
          ${pkgs.systemd}/bin/systemctl restart bluetooth.service
          up || { echo "hci0 still not powered" >&2; exit 1; }
        fi
        t0=$(date +%s)
        echo "adapter ready"

        hid_seen=0
        wait_hid() { # $1 = wait until this many seconds after t0
          while [ $(( $(date +%s) - t0 )) -lt "$1" ]; do
            for d in /sys/bus/hid/devices/0005:*; do
              case "$old" in *" ''${d##*/} "*) continue ;; esac
              echo "first BT HID input $(( $(date +%s) - t0 )) s after adapter ready (''${d##*/})"
              hid_seen=1
              return 0
            done
            sleep 0.5
          done
          return 1
        }

        lehid=0
        classic=()
        if [ -r "$state" ]; then
          while read -r mac kind; do
            case "$kind" in
              lehid) lehid=1 ;;
              classic) [[ $mac =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] && classic+=("$mac") ;;
            esac
          done < "$state"
          rm -f "$state"
        fi

        # An LE mouse that was connected before sleep gets the radio first.
        if [ "$lehid" = 1 ]; then wait_hid 15 || true; fi

        # Classic devices connected before sleep: one attempt each.
        for mac in "''${classic[@]}"; do
          if timeout 20 ${bctl} connect "$mac" >/dev/null 2>&1; then
            echo "reconnected $mac"
          else
            echo "could not reconnect $mac (off or out of range)"
          fi
        done

        # Measurement only, and only if an LE HID device was on before
        # sleep: short, so a quick re-suspend still finds this unit
        # finished and reloads btusb on its next resume.
        if [ "$lehid" = 1 ] && [ "$hid_seen" = 0 ]; then
          wait_hid 30 || echo "no BT HID input within 30 s after adapter ready"
        fi

        # At most one bluetoothd restart per resume (the one above counts).
        if [ "$restarted" = 0 ] && ! powered; then
          echo "hci0 powered off again; restarting bluetoothd" >&2
          ${pkgs.systemd}/bin/systemctl restart bluetooth.service
          up || { echo "hci0 still not powered" >&2; exit 1; }
        fi
      '';
    };
  };
}
