# Container slots: NixOS containers that behave like small VMs owned by
# another repo. This host declares only the shell of each slot (network,
# limits, isolation); what runs inside is whatever system the slot's
# deployer last switched to. Nothing here ever rewrites a slot's system.
#
# Deploying into a slot, from the other repo (builds run on this host's
# nix-daemon through the slot, so nothing unsigned has to be pushed; only
# .drv files, which are content-addressed, are copied):
#
#   nixos-rebuild switch --flake .#<cfg> \
#     --target-host root@<slot> --build-host root@<slot>
#
# An IPv6 <slot> goes in brackets, root@[<v6>]; nixos-rebuild strips them for
# ssh. A bare IPv6 literal fails in nix-copy-closure ("invalid URL
# authority").
#
# The guest config needs exactly one line beyond its own content:
# `boot.isNspawnContainer = true;` (what nixos-generate-config emits inside
# nspawn). It must also keep its own way in (sshd + a key for root): this
# host does not repair a slot that locked its deployer out.
#
# What the host provides, so the guest config does not have to:
#   - addresses: the slot's public v6 /128 (<ipv6Prefix>::5107:<id hex>) is
#     set on eth0 before the guest's init runs; isolated slots also get
#     10.43.<id>.2 and default routes via this host. lan slots take v4 from
#     the LAN's DHCP (NixOS's default dhcpcd does that) and their v6 default
#     route from the router's RAs; their MAC is fixed (02:43:51:07:00:<id>)
#     so the DHCP lease is stable.
#   - DNS: a public-resolver resolv.conf is copied in at every start (the
#     host's own points at resolved's stub, unreachable from the slot).
#   - first boot: a bootstrap system (sshd, `deployKeys` on root) seeds
#     the slot's profile if it has none yet. After that the profile belongs
#     to the deployer.
#
# Isolation: every slot runs in its own user namespace, at a fixed host uid
# base (uidBase: 0x60000000 + id * 0x10000; container uid n is host uid
# base + n), so its root is an unprivileged uid here and an untrusted user of
# this host's nix-daemon (sandboxed builds, cache substitution; no unsigned
# imports, no settings). It still reads the whole host /nix/store and shares
# the host kernel; its builds run in nix-daemon's cgroup, outside memoryMax
# and cpuQuota.
#
# Shares: `shares.<path in slot> = { source; user; }` serves a host directory
# into the slot through bindfs running as host account `user`. Every
# operation reaches `source` as that account, so its uid/gids alone decide
# what the slot may do there (for NFS sec=sys: what the server grants those
# ids). The slot sees the tree owned by its root and a+rwX, so any slot user
# can try anything and the host-side identity says yes or no; chown/chgrp are
# ignored. The kernel resolves symlinks inside the slot, but bindfs itself
# works by path, so a racing slot could steer an operation through a symlink
# it swaps in: give `user` rights on `source` only, never broader groups.
#
# Shares come and go without the slot noticing more than an empty directory
# meanwhile: the slot never waits for them (bam down at boot does not keep
# the slot down), and they reach it by mount propagation, not by the bind
# taken at slot start. The slot binds the (still empty) share directory
# under /run/container-slots/<slot> at start; each share unit mounts bindfs
# there afterwards (ordered after the slot). /run is a shared mount
# (systemd's default), and the slot's bind of a directory inside it is a
# slave of that peer group, so every later (re)mount there propagates into
# the running slot. A share retries forever; a hung NFS source only stalls
# I/O until its server is back.
#
# Modes (host-side only; the guest cannot tell and need not care):
#   isolated  routed veth; this host answers NDP on the bridge for the /128
#             and forwards. The slot reaches the internet only (v4 NAT'd);
#             LAN, private ranges, other slots and this host itself are
#             dropped; inbound is open to the /128 (the guest's firewall
#             decides), v4 inbound none.
#   lan       veth on the LAN bridge: a LAN peer like any other, unfiltered.
# Either way inbound from the internet additionally needs an allow rule for
# the slot's v6 address on the AIS router (`router-ais ipv6-rules add`).
#
# Enabling this turns the uplink NIC into a port of the bridge; the bridge
# keeps the NIC's MAC and takes over its DHCP/RA config. Point
# networking.publicIPv6.interface at the bridge.
#
# Rescue (admin only): reseed a slot with its bootstrap system:
#   rm /nix/var/nix/profiles/per-container/<slot>/system
#   systemctl restart container@<slot>
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.containerSlots;
  inherit (lib) mkOption types;

  hex = id: lib.toLower (lib.toHexString id);
  hex2 = id: lib.fixedWidthString 2 "0" (hex id);
  ipv6Of = slot: "${cfg.ipv6Prefix}::5107:${hex slot.id}";

  isolated = lib.filterAttrs (_: s: s.mode == "isolated") cfg.slots;
  # nspawn names the host side of the veth ve-<name> (routed) or vb-<name>
  # (bridged); the rules below match those names.
  vethOf = name: "ve-${name}";
  isolatedIfs = lib.concatMapStringsSep ", " (n: ''"${vethOf n}"'') (lib.attrNames isolated);

  profileDir = name: "/nix/var/nix/profiles/per-container/${name}";

  # Mounted read-only over the slot's /nix/var/nix. Nix's "auto" store
  # picks the local store whenever that directory is writable, which for
  # root in a slot it is (it lives in the container's own root), and then
  # fails remounting the shared store; environment.variables.NIX_REMOTE
  # does not reach `env -i` commands such as nixos-rebuild's --build-host
  # builds. Read-only, "auto" means the daemon. The module's own binds
  # (db, daemon-socket, profiles, gcroots) land on top; their mount points
  # must already exist here.
  nixStateStub = "/var/lib/container-slots/nix-var";

  resolvConf = pkgs.writeText "container-slot-resolv.conf" ''
    nameserver 9.9.9.9
    nameserver 2620:fe::fe
    nameserver 149.112.112.112
  '';

  bootstrap =
    name: slot:
    (pkgs.nixos {
      boot.isNspawnContainer = true;
      networking.hostName = name;
      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keys = slot.deployKeys;
      system.stateVersion = config.system.stateVersion;
    }).toplevel;

  seed =
    name: slot:
    pkgs.writeShellScript "container-slot-seed-${name}" ''
      mkdir -p ${nixStateStub}/{db,daemon-socket,profiles,gcroots}
      if [ ! -e ${profileDir name}/system ]; then
        mkdir -p ${profileDir name}
        ${config.nix.package}/bin/nix-env -p ${profileDir name}/system \
          --set ${bootstrap name slot}
      fi
    '';

  uidBase = slot: 1610612736 + slot.id * 65536;

  shareName = path: lib.removePrefix "-" (lib.replaceStrings [ "/" ] [ "-" ] path);
  slotRun = name: "/run/container-slots/${name}";
  shareMount = name: path: "${slotRun name}/${shareName path}";
  shareUnit = name: path: "container-slot-${name}-${shareName path}";

  # Before the slot starts: create the share mount points (owned by the
  # share's account, which fusermount requires). findmnt reads mountinfo
  # only: nothing here may stat a FUSE mount whose NFS source might hang.
  slotPrep =
    name: slot:
    pkgs.writeShellScript "container-slot-prep-${name}" ''
      PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux ]}
      install -d -m 0711 /run/container-slots ${slotRun name}
      ${lib.concatStrings (
        lib.mapAttrsToList (path: share: ''
          m=${shareMount name path}
          findmnt -rn --mountpoint "$m" >/dev/null || install -d -m 0700 -o ${share.user} "$m"
        '') slot.shares
      )}
    '';

  shareOptions = {
    options = {
      source = mkOption {
        type = types.str;
        example = "/vault/parquet";
        description = "Host directory served into the slot.";
      };
      user = mkOption {
        type = types.str;
        description = "Host account every operation on `source` runs as; its rights are the slot's rights.";
      };
    };
  };

  slotOptions = {
    options = {
      id = mkOption {
        type = types.ints.between 1 254;
        description = ''
          Stable slot number; derives the slot's addresses (v6
          <ipv6Prefix>::5107:<id hex>, isolated v4 10.43.<id>.2). Never
          reuse or renumber: the router allow rule is keyed on the address.
        '';
      };
      mode = mkOption {
        type = types.enum [
          "isolated"
          "lan"
        ];
        description = "isolated: public v6 + outbound internet only. lan: a peer on the local network, also on its public v6.";
      };
      deployKeys = mkOption {
        type = types.listOf types.str;
        description = "SSH keys for root in the bootstrap system. Used only to seed a slot without a system; deployed guests own their keys.";
      };
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "4G";
        description = "MemoryMax= of container@<slot> (the slot's processes; not its nix builds).";
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "200%";
        description = "CPUQuota= of container@<slot>.";
      };
      shares = mkOption {
        type = types.attrsOf (types.submodule shareOptions);
        default = { };
        example = {
          "/vault/parquet" = {
            source = "/vault/parquet";
            user = "slot-foo";
          };
        };
        description = "Host directories served into the slot, keyed by their path inside it (see the module header).";
      };
    };
  };
in
{
  options.hyper.containerSlots = {
    enable = lib.mkEnableOption "container slots (bridges the uplink)";
    uplink = mkOption {
      type = types.str;
      example = "enp6s0";
      description = "Physical LAN NIC; becomes a port of `bridge`.";
    };
    uplinkMac = mkOption {
      type = types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}";
      description = "The uplink's MAC, given to the bridge so the host keeps its DHCP lease and SLAAC address.";
    };
    bridge = mkOption {
      type = types.str;
      default = "br0";
      description = "LAN bridge that carries the host's own address and the lan slots.";
    };
    lanIPv4 = mkOption {
      type = types.str;
      default = "192.168.8.0/24";
      description = "The LAN's v4 subnet (isolated slots must not reach it).";
    };
    ipv6Prefix = mkOption {
      type = types.str;
      default = "2405:9800:b901:94e3";
      description = "First four groups of the LAN /64 the router advertises; slot addresses live in it.";
    };
    slots = mkOption {
      type = types.attrsOf (types.submodule slotOptions);
      default = { };
      description = "Slots by name (<= 11 chars: nspawn's host veth names are ve-/vb-<name>, capped at 15).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.mapAttrsToList (name: _: {
        assertion = builtins.stringLength name <= 11;
        message = "hyper.containerSlots.slots.${name}: slot names must be <= 11 chars";
      }) cfg.slots
      ++ lib.mapAttrsToList (name: slot: {
        assertion = lib.count (s: s.id == slot.id) (lib.attrValues cfg.slots) == 1;
        message = "hyper.containerSlots.slots.${name}: id ${toString slot.id} is not unique";
      }) cfg.slots;

    # --- the LAN bridge -------------------------------------------------
    systemd.network = {
      netdevs."20-${cfg.bridge}".netdevConfig = {
        Kind = "bridge";
        Name = cfg.bridge;
        MACAddress = cfg.uplinkMac;
      };
      # The NIC's own network (nixos-facter's 40-<uplink>) becomes a bare
      # bridge port; its DHCP/RA duties move to the bridge. Forcing
      # networkConfig also drops the DHCP=yes networkd derives from it.
      # Stage 2 only: the initrd's own 40-<uplink> (remote unlock) keeps
      # DHCP, so do not touch networking.interfaces.<uplink> instead.
      networks."40-${cfg.uplink}".networkConfig = lib.mkForce { Bridge = cfg.bridge; };
      networks."40-${cfg.bridge}" = {
        matchConfig.Name = cfg.bridge;
        DHCP = "yes";
        networkConfig = {
          IPv6PrivacyExtensions = "kernel";
          # networkd defaults RA handling off on bridges and when
          # forwarding is on; this host needs both and its own SLAAC.
          IPv6AcceptRA = true;
          IPv6ProxyNDP = isolated != { };
          IPv6ProxyNDPAddress = lib.mapAttrsToList (_: ipv6Of) isolated;
        };
      };
      # systemd ships 80-container-ve/vb.network, which would give the
      # slot veths a DHCP server, RAs and masquerading of their own. The
      # container units configure these links; networkd stays off them.
      networks."10-container-slots" = lib.mkIf (cfg.slots != { }) {
        matchConfig.Name = lib.concatMapStringsSep " " (n: "ve-${n} vb-${n}") (lib.attrNames cfg.slots);
        linkConfig.Unmanaged = true;
      };
      # networkd drops routes it did not create whenever it (re)starts,
      # i.e. on every host switch that touches it. The container units
      # add the host-side slot routes; keep them.
      config.networkConfig.ManageForeignRoutes = false;
    };
    networking.networkmanager.unmanaged = [
      "interface-name:${cfg.uplink}"
      "interface-name:${cfg.bridge}"
    ];

    # mkDefault: other modules may set the same value (see bam).
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
    boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = lib.mkDefault 1;

    # --- the slots ------------------------------------------------------
    containers = lib.mapAttrs (
      name: slot:
      {
        autoStart = true;
        privateUsers = uidBase slot;
        privateNetwork = true;
        extraFlags = [
          "--bind-ro=${nixStateStub}:/nix/var/nix"
          # implied by "pick", not by a numeric base: without it the root
          # tree stays host-root-owned, i.e. nobody's inside the slot
          "--private-users-ownership=auto"
        ];
        bindMounts = lib.mapAttrs (path: _: {
          hostPath = shareMount name path;
          isReadOnly = false;
        }) slot.shares;
        # mkForce + an empty `config`: the containers module's own
        # assertions read `containers.<n>.config.nix.*` unconditionally, so a
        # path-only container fails to evaluate without one. The forced
        # path wins, so this stub is never built.
        config = { };
        # Resolved inside the container, where <profileDir> is bind-mounted
        # on /nix/var/nix/profiles: always the slot's current generation.
        path = lib.mkForce "/nix/var/nix/profiles/system";
      }
      // (
        if slot.mode == "isolated" then
          {
            hostAddress = "10.43.${toString slot.id}.1";
            localAddress = "10.43.${toString slot.id}.2";
            hostAddress6 = "fd43:5107::${hex slot.id}:1";
            localAddress6 = ipv6Of slot;
          }
        else
          {
            hostBridge = cfg.bridge;
            localAddress6 = "${ipv6Of slot}/64";
            localMacAddress = "02:43:51:07:00:${hex2 slot.id}";
          }
      )
    ) cfg.slots;

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: slot:
        lib.nameValuePair "container@${name}" {
          serviceConfig = {
            ExecStartPre = [
              "+${slotPrep name slot}"
              (seed name slot)
            ];
            # The start script copies the host's /etc/resolv.conf into the
            # slot; in this unit's mount namespace that is the public one.
            BindReadOnlyPaths = [ "${resolvConf}:/etc/resolv.conf" ];
          }
          // lib.optionalAttrs (slot.memoryMax != null) { MemoryMax = slot.memoryMax; }
          // lib.optionalAttrs (slot.cpuQuota != null) { CPUQuota = slot.cpuQuota; };
        }
      ) cfg.slots)

      (lib.concatMapAttrs (
        name: slot:
        lib.mapAttrs' (
          path: share:
          let
            mnt = shareMount name path;
            owner = toString (uidBase slot);
          in
          lib.nameValuePair (shareUnit name path) {
            description = "Share ${share.source} into slot ${name} at ${path}";
            # Started with the slot, after it (its bind of the empty mount
            # point must predate this mount), restarted and stopped with it.
            wantedBy = [ "container@${name}.service" ];
            partOf = [ "container@${name}.service" ];
            after = [ "container@${name}.service" ];
            unitConfig = {
              RequiresMountsFor = [ share.source ];
              StartLimitIntervalSec = 0;
            };
            # fusermount3 (setuid wrapper) mounts for the unprivileged user
            path = [ "/run/wrappers" ];
            serviceConfig = {
              User = share.user;
              ExecStart = lib.escapeShellArgs [
                "${pkgs.bindfs}/bin/bindfs"
                "-f"
                "-o"
                "allow_other"
                "--force-user=${owner}"
                "--force-group=${owner}"
                "--perms=a+rwX"
                "--chown-ignore"
                "--chgrp-ignore"
                "--xattr-none"
                # The slot's umask reaches bindfs as the create mode, and on
                # an ACL'd tree the group bits are the mask: 0644 would cap
                # every group ACL (vault's own writers too) at read-only.
                "--create-with-perms=g+rwX"
                share.source
                mnt
              ];
              # -c: no canonicalisation, i.e. no stat of a possibly hung mount
              ExecStopPost = "-+${pkgs.util-linux}/bin/umount -l -c ${mnt}";
              Restart = "always";
              RestartSec = 5;
            };
          }
        ) slot.shares
      ) cfg.slots)
    ];

    programs.fuse.userAllowOther = lib.mkIf (lib.any (s: s.shares != { }) (lib.attrValues cfg.slots)) true;

    # --- isolated-mode policy --------------------------------------------
    networking.nftables.tables.container-slots = lib.mkIf (isolated != { }) {
      family = "inet";
      content = ''
        # isolated slot -> this host: only what the link needs
        chain input {
          type filter hook input priority filter; policy accept;
          iifname { ${isolatedIfs} } jump isolated-to-host
        }
        chain isolated-to-host {
          ct state established,related accept
          icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
          drop
        }

        chain forward {
          type filter hook forward priority filter; policy accept;
          iifname { ${isolatedIfs} } jump isolated-out
          oifname { ${isolatedIfs} } jump isolated-in
        }
        chain isolated-out {
          ${lib.concatStrings (
            lib.mapAttrsToList (name: slot: ''
              iifname "${vethOf name}" ip saddr != 10.43.${toString slot.id}.2 drop
              iifname "${vethOf name}" ip6 saddr != ${ipv6Of slot} drop
            '') isolated
          )}
          ct state established,related accept
          oifname != "${cfg.bridge}" drop
          ip daddr { ${cfg.lanIPv4}, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } drop
          ip6 daddr { ${cfg.ipv6Prefix}::/64, fc00::/7, fe80::/10 } drop
          accept
        }
        chain isolated-in {
          ct state established,related accept
          ${lib.concatStrings (
            lib.mapAttrsToList (name: slot: ''
              oifname "${vethOf name}" ip6 daddr ${ipv6Of slot} accept
            '') isolated
          )}
          drop
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 10.43.0.0/16 oifname "${cfg.bridge}" masquerade
        }
      '';
    };
  };
}
