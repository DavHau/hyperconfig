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
  `space-usb@<name>:<kernel name>` (./usb-ports.py), which allows that one
  device's major:minor in the container's cgroup (a runtime DeviceAllow:
  the unit's own list plus the devices handed over now) and mknods its node
  inside the guest's mount namespace, 0660 and owned by the space's user
  and group (libusb, hidraw, serial, block without root): every node on
  the port, whatever its kind or USB id. On unplug it revokes the
  number first, then removes the node: a node the guest copied or
  hard-linked opens nothing once the number goes to the next device. No
  device class is allowed as such; the container's unit file has no USB in
  it. Re-enumeration (DFU, BOOTSEL, JTAG/serial switches) is just another
  add event. The node is made in a fresh directory of host root's and
  renamed into place, every directory opened without following symlinks
  and checked to be on the guest's /dev tmpfs, so the guest's root can't
  redirect it onto a host file; the namespace is entered through a pidfd
  of the leader, checked to be the container's pid 1.

  Network adapters on a port go into the guest's network namespace
  (`space-usb-net@<name>:<ifindex>`, after udev renamed them; usb<N>
  there; this host's NetworkManager and networkd leave them alone). An
  adapter that comes back to this host (the guest's namespace went away)
  is renamed `spusb<ifindex>` on its way in, never kept under a name the
  guest chose, stays down and unmanaged, and goes into the next guest.
  The guest's networkd takes an address by DHCP on it, no gateway or DNS,
  and the lease's prefix route only into a table of its own (4242) that
  the guest consults after its own specific routes and before its
  default route, only for private and link-local destinations (10/8,
  172.16/12, 192.168/16, 169.254/16) and ignoring any route there
  shorter than /16: a KVM's or board's DHCP (a hostile /1 netmask, or a
  public lease like 1.1.1.5/16, included) can't take the guest's
  internet. Left: the leased address itself (the kernel's local route),
  and a lease of /16 or longer inside those private ranges still wins
  there (a device leasing 192.168.18.x/24 takes that subnet for the
  guest, e.g. a home LAN reached through the host).

  Listing a port gives the guest unfiltered network through whatever
  adapter appears there: this host's firewall never sees that traffic,
  and the guest's root can add any route or address over it. List only
  ports whose devices the space may talk to freely.

  Input devices on a port are switched off for this host's kernel the
  moment udev sees them (`inhibited` on the input device: no event
  reaches the VT keyboard, Ctrl-Alt-Del, SysRq, evdev readers or a
  writer injecting into an event node), logind doesn't take their keys
  as power or sleep buttons (no `power-switch` tag), and libinput
  ignores them. The guest reads them through hidraw (raw reports,
  hid core keeps those flowing); their event nodes stay silent there
  too. In the few milliseconds between the kernel registering the
  device and udev processing it, the VT keyboard still sees its keys:
  so on a host with any such port Ctrl-Alt-Del does nothing
  (ctrl-alt-del.target is a no-op target, CtrlAltDelBurstAction=none),
  for every keyboard: a local Ctrl-Alt-Del no longer reboots this host.
  A device re-enumerating to send it in its first report gets nothing.
  Left in that window: SysRq (if enabled) and evdev readers.

  Block devices on a port are left alone by this host: udev doesn't
  probe them for filesystems (so no LVM, md or bcache activation) and
  makes no /dev/disk/by-* link (by-id, by-path, by-uuid, by-label, ...),
  also in the initrd: a ZFS import from /dev/disk/by-id (boot.zfs.devNodes
  on som and amy, the initrd's `zpool import -d`) never sees them, so a
  guest-written stick with a fake pool of the root pool's name left in at
  reboot can't break the import. udisks hides them (no automount, no
  desktop entry, mounting needs admin). The guest has raw write access to
  them. A manual `zpool import`, `lvm`/`pvscan` or `mdadm --scan` without
  a device filter (-d) still reads every disk, these too.

  A restarted container starts with an empty /dev, its unit's own list
  and none of the adapters (back in the host's namespace):
  `space-usb-replay-<name>` (wanted by the container's unit through a
  .wants link, the unit file unchanged) moves the adapters and restarts
  the plugged devices' units. It is a plain oneshot (no
  RemainAfterExit), so every start of the container runs it again,
  including the automatic one after a reboot from inside the guest.

  Everything on a listed port is handed over, keyboards, mice and network
  adapters too (Dave's KVM devices have both): the guest can read their
  raw reports, i.e. what is typed on them; this host gets nothing from
  them. Don't list a port a keyboard used on this host sits on.

  Trust: whatever is plugged into such a port talks to this host's kernel
  drivers (usb-storage, cdc-acm, hid, ...) like any USB device; the guest
  gets raw access to it, nothing else.
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
  want = name: inst: ''TAG+="systemd", ENV{SYSTEMD_WANTS}+="${inst}.service"'';
  ports = lib.concatMap (s: s.usbPorts) (lib.attrValues spaces);
  rules = lib.concatStrings (
    lib.mapAttrsToList (
      name: s:
      lib.concatMapStrings (port: ''
        ACTION!="remove", DEVPATH=="*/${port}/*", SUBSYSTEM=="input", KERNEL=="input*", ATTR{inhibited}="1"
        ACTION!="remove", DEVPATH=="*/${port}/*", SUBSYSTEM=="input", ENV{LIBINPUT_IGNORE_DEVICE}="1", TAG-="power-switch"
        ACTION!="remove", DEVPATH=="*/${port}/*", SUBSYSTEM=="block", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0", ENV{UDISKS_SYSTEM}="1"
        ACTION=="add", DEVPATH=="*/${port}/*", SUBSYSTEM=="net", NAME="spusb$attr{ifindex}"
        ACTION!="remove", DEVPATH=="*/${port}/*", SUBSYSTEM=="net", ENV{NM_UNMANAGED}="1", ENV{ID_NET_MANAGED_BY}="space-usb", ${want name "space-usb-net@${name}:$attr{ifindex}"}
        ACTION!="remove", DEVPATH=="*/${port}/*", SUBSYSTEM!="usb", ENV{DEVNAME}=="?*", ${want name "space-usb@${name}:%k"}
        ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="*/${port}", ${want name "space-usb@${name}:usb-%k"}
        ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="*/${port}/*", ${want name "space-usb@${name}:usb-%k"}
      '') s.usbPorts
    ) spaces
  );
  # Before 60-persistent-storage.rules: none of it for block devices on
  # the ports (its first test is the RULES flag): no blkid probe, so no
  # ID_FS_TYPE, which LVM's pvscan, mdadm's incremental assembly and
  # bcache key on, and no /dev/disk/by-* links, which ZFS's imports from
  # /dev/disk/by-id scan. Not SYSTEMD_READY=0: that would stop the device
  # unit, and with it the SYSTEMD_WANTS hand-over above.
  noProbe = pkgs.writeTextDir "lib/udev/rules.d/59-space-usb-no-probe.rules" (
    lib.concatMapStrings (port: ''
      SUBSYSTEM=="block", DEVPATH=="*/${port}/*", ENV{UDEV_DISABLE_PERSISTENT_STORAGE_RULES_FLAG}="1", ENV{UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG}="1"
    '') ports
  );
  # per space: its ports, the guest's id base, the container unit's own
  # DeviceAllow (./usb-ports.py rewrites the runtime list from it)
  spaceConfig = pkgs.writeText "space-usb.json" (
    builtins.toJSON (
      lib.mapAttrs (name: s: {
        ports = s.usbPorts;
        base = guestIdBase name;
        # the space's user (and its group, gid = uid) inside the guest
        uid = (import ./registry.nix).${name}.uid;
        deviceAllow = config.systemd.services."container@${name}".serviceConfig.DeviceAllow or [ ];
      }) spaces
    )
  );
  attach = "${pkgs.python3.interpreter} ${./usb-ports.py} ${spaceConfig}";
  path = [
    pkgs.systemd
  ];
  # The guest's side of a network interface on a port (usb<N> there): DHCP
  # for an address on its link, nothing else from it (no default route,
  # no DNS: a KVM's or board's DHCP must not take the guest's internet).
  # The lease's prefix route goes into its own table, consulted after the
  # main table's specific routes (rule 1: main without its default) and
  # before the default, only for private and link-local destinations (a
  # public lease like 1.1.1.5/16 would otherwise take 1.1/16) and only
  # for routes of /16 or longer (a hostile /1 netmask would otherwise take
  # half the internet). v4 only: the link gets no v6 but its fe80::/64.
  # networkd touches nothing but these.
  usbTable = 4242;
  usbDests = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
  ];
  guestNet = {
    systemd.network = {
      enable = true;
      wait-online.enable = false;
      config.networkConfig = {
        ManageForeignRoutes = false;
        ManageForeignRoutingPolicyRules = false;
      };
      networks."50-space-usb" = {
        matchConfig.Name = "usb*";
        networkConfig = {
          DHCP = "ipv4";
          LinkLocalAddressing = "ipv6";
          IPv6AcceptRA = false;
        };
        routingPolicyRules = [
          {
            Table = "main";
            SuppressPrefixLength = 0;
            Priority = 4240;
          }
        ]
        ++ map (to: {
          To = to;
          Table = usbTable;
          SuppressPrefixLength = 15;
          Priority = 4242;
        }) usbDests;
        dhcpV4Config = {
          RouteTable = usbTable;
          UseRoutes = false;
          UseGateway = false;
          UseDNS = false;
          UseNTP = false;
          UseHostname = false;
          UseDomains = false;
        };
      };
    };
  };
in
{
  options.hyper.spaces = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (sub: {
        config.guestModules = lib.mkIf (sub.config.usbPorts != [ ]) [ guestNet ];
        options.usbPorts = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-9]/usb[0-9]+/[0-9]+-[0-9.]+");
          default = [ ];
          example = [ "0000:0a:00.0/usb2/2-2" "0000:0a:00.0/usb1/1-1" ];
          description = "Physical USB ports of this host whose devices appear in the guest (./usb-ports.nix).";
        };
      })
    );
  };

  config = lib.mkIf (spaces != { }) {
    services.udev.extraRules = rules;
    services.udev.packages = [ noProbe ];
    # a stick on the port at boot: no LVM/md activation or by-id link in
    # the initrd either (its zpool import scans /dev/disk/by-id)
    boot.initrd.services.udev.packages = [ noProbe ];
    # A keyboard on a port reaches the VT keyboard before udev inhibits it
    # (see the header): Ctrl-Alt-Del, also pressed 7 times in 2 s, does
    # nothing on this host, from any keyboard.
    systemd.ctrlAltDelUnit = "space-usb-ctrl-alt-del.target";
    systemd.targets.space-usb-ctrl-alt-del = {
      description = "No-op key target (spaces' USB ports)";
      # no-op: pulls in nothing
      unitConfig.DefaultDependencies = false;
    };
    systemd.settings.Manager.CtrlAltDelBurstAction = "none";
    systemd.services =
      {
        "space-usb@" = {
          description = "USB device %i into its space";
          # wanted by the device unit: stopped (node removed) when it goes.
          # The rules match every event but remove: a later bind/change
          # event re-reads them, and one without the want would stop this.
          unitConfig.StopWhenUnneeded = true;
          inherit path;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${attach} add %i";
            ExecStop = "${attach} remove %i";
          };
        };
        # a revocation that failed (the space's devices' records left as
        # .revoking), retried with backoff until a list without them is
        # set; started by ./usb-ports.py when one fails
        "space-usb-revoke@" = {
          description = "Revoke USB devices of %i";
          inherit path;
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${attach} revoke %i";
            Restart = "on-failure";
            RestartSec = 1;
            RestartSteps = 5;
            RestartMaxDelaySec = 30;
          };
        };
        # a network interface on a port into the guest's netns, once per
        # appearance (each replug or reset is a new ifindex)
        "space-usb-net@" = {
          description = "USB network interface %i into its space";
          path = path ++ [ pkgs.iproute2 ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${attach} net %i";
          };
        };
      }
      # A (re)started container has an empty /dev and its unit's own
      # DeviceAllow: hand over again what is plugged in. Wanted by the
      # container's unit from outside (a .wants link), so the container's
      # unit file stays as it is.
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair "space-usb-replay-${name}" {
          description = "USB devices into the restarted ${name}";
          # Every start of the container pulls this in again (Wants=):
          # an explicit restart, and the automatic one after a reboot from
          # inside the guest (exit 133, Restart=), which PartOf= would miss.
          # No RemainAfterExit: an active leftover would make that start a
          # no-op.
          wantedBy = [ "container@${name}.service" ];
          after = [ "container@${name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${attach} replay ${name}";
          };
          path = path ++ [ pkgs.iproute2 ];
        }
      ) spaces;
  };
}
