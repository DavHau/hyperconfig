/*
  USB ports of this host handed to a space container
  (hyper.spaces.<name>.usbPorts): every device that appears on one of those
  physical ports, at any time, shows up in the running guest; devices on
  other ports never do.

  A port is the sysfs path of what is plugged into it, from the controller:
  "<pci addr>/usb<bus>/<bus>-<port>", e.g. "0000:0a:00.0/usb2/2-2" (the
  DEVPATH of `udevadm info /sys/bus/usb/devices/2-2`). A USB 3 socket has a
  USB 2 twin on the controller's other bus (sysfs usbN-portM/peer): list
  both, or a slow device in the same socket lands on the twin. Bus numbers
  are not in udev's ID_PATH, so ports are matched by DEVPATH.

  How: nspawn binds nothing after start and refuses `machinectl bind` with
  a user namespace, so a udev rule on the port starts
  `space-usb@<name>:<kernel name>`, which mknods the node inside the
  guest's mount namespace, owned by the guest's root and its disk (block),
  dialout (tty) or root group, and removes it on unplug. The container's
  cgroup allows the device classes boards and sticks use (block-sd,
  char-usb_device, ttyUSB, ttyACM, hidraw); the nodes decide which
  devices: only those on the listed ports get one. Re-enumeration (DFU,
  BOOTSEL, JTAG/serial switches) is just another add event.

  Keyboards and mice (HID boot interfaces) are never handed over, even on
  a listed port: their raw reports are what is typed on this host. Debug
  probes (CMSIS-DAP and other non-boot HID) still are.

  Trust: whatever is plugged into such a port talks to this host's kernel
  drivers (usb-storage, cdc-acm, ...) like any USB device; the guest gets
  raw access to it, nothing else.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  spaces = lib.filterAttrs (_: s: s.enable && s.usbPorts != [ ]) config.hyper.spaces;
  guestIdBase =
    name:
    let
      p = config.containers.${name}.privateUsers;
    in
    if p == "no" then 0 else p;
  want = name: inst: ''TAG+="systemd", ENV{SYSTEMD_WANTS}+="space-usb@${name}:${inst}.service"'';
  rules = ''
    # Keyboards and mice (HID boot interfaces) stay on the host even on a
    # listed port: their raw reports are the keystrokes typed here.
    ACTION=="add", SUBSYSTEM=="hidraw", ATTRS{bInterfaceClass}=="03", ATTRS{bInterfaceSubClass}=="01", GOTO="space_usb_end"
    ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_USB_INTERFACES}=="*:0301*", GOTO="space_usb_end"
  '' + lib.concatStrings (
    lib.mapAttrsToList (
      name: s:
      lib.concatMapStrings (port: ''
        ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk|partition", DEVPATH=="*/${port}/*", ${want name "%k"}
        ACTION=="add", SUBSYSTEM=="tty", KERNEL=="ttyUSB*|ttyACM*", DEVPATH=="*/${port}/*", ${want name "%k"}
        ACTION=="add", SUBSYSTEM=="hidraw", DEVPATH=="*/${port}/*", ${want name "%k"}
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="*/${port}", ${want name "usb-%k"}
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="*/${port}/*", ${want name "usb-%k"}
      '') s.usbPorts
    ) spaces
  ) + ''
    LABEL="space_usb_end"
  '';
  bases = lib.concatStrings (
    lib.mapAttrsToList (name: _: ''
      ${name}) base=${toString (guestIdBase name)} ;;
    '') spaces
  );
  attach = pkgs.writeShellScript "space-usb" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.systemd ]}
    inst=$1 action=$2
    name=''${inst%%:*} dev=''${inst#*:}
    case $name in
    ${bases}
      *) echo "space-usb: unknown space $name" >&2; exit 1 ;;
    esac
    state=/run/space-usb/$inst
    leader=$(machinectl show "$name" -p Leader --value 2>/dev/null || true)
    ns() { nsenter -t "$leader" -m -- "$@"; }
    if [ "$action" = remove ]; then
      if [ -r "$state" ] && [ -n "$leader" ] && [ "$leader" != 0 ]; then
        ns rm -f "$(cat "$state")" || true
      fi
      rm -f "$state"
      exit 0
    fi
    case $dev in
      usb-*) node=/dev/$(udevadm info -q name -p "/sys/bus/usb/devices/''${dev#usb-}") ;;
      *) node=/dev/$dev ;;
    esac
    [ -e "$node" ] || exit 0
    [ -n "$leader" ] && [ "$leader" != 0 ] || { echo "space-usb: $name not running"; exit 0; }
    maj=$((0x$(stat -c %t "$node"))) min=$((0x$(stat -c %T "$node")))
    type=c; [ -b "$node" ] && type=b
    case $node in
      /dev/sd*) grp=6 ;;
      /dev/tty*) grp=27 ;;
      *) grp=0 ;;
    esac
    ns mkdir -p "$(dirname "$node")"
    ns rm -f "$node"
    ns mknod -m 0660 "$node" "$type" "$maj" "$min"
    ns chown "$base:$((base + grp))" "$node"
    mkdir -p /run/space-usb
    echo "$node" > "$state"
    echo "space-usb: $node ($type $maj:$min) into $name"
  '';
in
{
  options.hyper.spaces = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.usbPorts = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-9]/usb[0-9]+/[0-9]+-[0-9.]+");
          default = [ ];
          example = [ "0000:0a:00.0/usb2/2-2" "0000:0a:00.0/usb1/1-1" ];
          description = "Physical USB ports of this host whose devices appear in the guest (./usb-ports.nix).";
        };
      }
    );
  };

  config = lib.mkIf (spaces != { }) {
    services.udev.extraRules = rules;
    systemd.services =
      {
        "space-usb@" = {
          description = "USB device %i into its space";
          # wanted by the device unit: stopped (node removed) when it goes
          unitConfig.StopWhenUnneeded = true;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${attach} %i add";
            ExecStop = "${attach} %i remove";
          };
        };
      }
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair "container@${name}" {
          serviceConfig.DeviceAllow = [
            "block-sd rw"
            "char-usb_device rw"
            "char-ttyUSB rw"
            "char-ttyACM rw"
            "char-hidraw rw"
          ];
        }
      ) spaces;
  };
}
