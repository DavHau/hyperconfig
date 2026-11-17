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
  there; this host's NetworkManager and networkd leave them alone): the guest's networkd takes an
  address by DHCP on them but no route, gateway or DNS (a KVM's or
  board's DHCP must not take the guest's internet). Input devices on a
  port are ignored by this host's libinput (the desktop doesn't type
  with them); their nodes go to the guest like the rest.

  A restarted container starts with an empty /dev, its unit's own list
  and none of the adapters (back in the host's namespace):
  `space-usb-replay-<name>` (wanted by the container's unit through a
  .wants link, the unit file unchanged) moves the adapters and restarts
  the plugged devices' units.

  Everything on a listed port is handed over, keyboards, mice and network
  adapters too
  (Dave's KVM devices have both): the guest can read their raw reports,
  i.e. what is typed on them, while this host's input layer still gets
  them as well. Don't list a port a keyboard used on this host sits on.

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
  want = name: inst: ''TAG+="systemd", ENV{SYSTEMD_WANTS}+="${inst}.service"'';
  rules = lib.concatStrings (
    lib.mapAttrsToList (
      name: s:
      lib.concatMapStrings (port: ''
        DEVPATH=="*/${port}/*", SUBSYSTEM=="input", ENV{LIBINPUT_IGNORE_DEVICE}="1"
        ACTION=="add|move", DEVPATH=="*/${port}/*", SUBSYSTEM=="net", ENV{NM_UNMANAGED}="1", ENV{ID_NET_MANAGED_BY}="space-usb", ${want name "space-usb-net@${name}:$attr{ifindex}"}
        ACTION!="remove", DEVPATH=="*/${port}/*", SUBSYSTEM!="usb", ENV{DEVNAME}=="?*", ${want name "space-usb@${name}:%k"}
        ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="*/${port}", ${want name "space-usb@${name}:usb-%k"}
        ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", DEVPATH=="*/${port}/*", ${want name "space-usb@${name}:usb-%k"}
      '') s.usbPorts
    ) spaces
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
  # networkd touches nothing but these.
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
        dhcpV4Config = {
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
          wantedBy = [ "container@${name}.service" ];
          after = [ "container@${name}.service" ];
          partOf = [ "container@${name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${attach} replay ${name}";
          };
          path = path ++ [ pkgs.iproute2 ];
        }
      ) spaces;
  };
}
