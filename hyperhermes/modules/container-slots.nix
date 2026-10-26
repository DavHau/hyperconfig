# Container slots: NixOS containers that behave like small VMs owned by
# another repo. This host declares only the shell of each slot (network,
# limits, isolation); what runs inside is whatever system the slot's
# deployer last switched to. Nothing here ever rewrites a slot's system.
# Generic, not tied to hermes: `services.container-slots`. The agents' own
# slots (./slots) are slots of this module.
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
# host does not repair a slot that locked its deployer out. The simplest way
# is the bootstrap's own: `services.openssh.authorizedKeysFiles =
# [ "/var/lib/container-slot/authorized_keys" ];` (see first boot below).
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
#   - first boot: a bootstrap system (sshd) seeds the slot's profile if it
#     has none yet. After that the profile belongs to the deployer. Its sshd
#     lets in root with the slot's `deployKeys` (default: the host-wide
#     list) and the keys in its `deployKeyFiles` (runtime files, read
#     then; each must be a regular file owned by root, read without
#     following a link), from a file this host bind-mounts read-only at
#     /var/lib/container-slot/authorized_keys at every start. The keys live
#     in that file, not in the bootstrap system, so one bootstrap serves
#     slots with different deployers. The file is owned by the slot's root
#     (sshd's StrictModes refuses a file owned by anyone else, and a host
#     root file shows up as nobody in the slot's user namespace); the
#     read-only bind keeps the slot from rewriting it. It sits under /var,
#     not /etc, so it survives a guest whose /etc is an overlay.
#   - host key: one ed25519 key per slot, generated here once
#     (/var/lib/container-slots/host-keys/<slot>/) and bind-mounted
#     read-only at /var/lib/container-slot/ssh_host_ed25519_key the same
#     way, so it survives resets, hard resets and redeploys, and this host
#     can pin it: known_hosts next to it lists the slot's addresses
#     (`hostKeysDir`). The bootstrap's sshd uses it; a deployed guest
#     keeps it with `services.openssh.hostKeys = [ { type = "ed25519";
#     path = "/var/lib/container-slot/ssh_host_ed25519_key"; } ];`, or
#     clients that pin it refuse the slot.
#   - start: `autoStart` (default on) starts the slot at boot; off, the
#     unit container@<slot> exists and something else starts it
#     (./slots).
#   - the root tree: the slot's root owns /var/lib/nixos-containers/<slot>
#     (user namespace, ownership auto), but nixpkgs' container start script
#     runs as host root on it (mkdir -p, chmod, touch, cp) and follows
#     symlinks. A slot that replaced /root by a link to / would get host
#     root to chmod 0700 this host's /. So before every start, with the
#     slot stopped (nothing of it runs to race the check), the prep step
#     refuses to start a slot whose usr, usr/bin, etc, var, var/lib,
#     var/lib/private or root is a symlink (checked top-down, so each
#     check resolves no planted link), and removes a symlinked
#     etc/resolv.conf (replaced by the copy anyway) and any symlinked
#     etc/machine-id: the script touches it unless it exists, and whether
#     a link's target exists is host state the agent can flip between the
#     check and the touch (a second hop in its own home). etc/os-release
#     stays: a NixOS guest's is always a link, and the script already
#     leaves a link alone. nixpkgs upstream has no fix (checked 2026-10).
#
# Evaluation cost: this host evaluates no NixOS system per slot. All slots
# share one bootstrap system (no keys of its own, see first boot; nspawn
# sets the hostname to the slot name), and the containers module's
# per-container `config` stays undefined, so its eval-config is never
# forced.
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
# meanwhile: the slot never waits for them (a share's NFS server down at
# boot does not keep the slot down), and they reach it by mount
# propagation, not by the bind taken at slot start. The slot binds the
# (still empty) share directory
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
#             LAN, private ranges, `isolatedBlockedDestinations`, other
#             slots and this host itself are dropped; inbound is open to the
#             /128 (the guest's firewall decides). v4 inbound only on
#             `publicIPv4Ports`: TCP arriving on `publicIPv4Interface` (the
#             link a public IPv4 arrives on) at one of those ports is DNATed
#             to the same port at 10.43.<id>.2, client address kept. With
#             `isolatedEgress`, every connection the slot opens leaves
#             through that interface (e.g. a VPN tunnel), masqueraded to
#             its addresses, v6 included; connections that came in (v6
#             from the internet, forwarded v4) answer the way they came. A
#             forward-chain kill switch drops the slot's own connections on
#             any other interface, so a dead tunnel means no egress, not the
#             home uplink. It needs a loose reverse-path filter (asserted).
#             While a slot is stopped, unreachable routes for 10.43.0.0/16
#             and its /128 keep its addresses from falling back to the LAN
#             (where any peer could claim the v6 by NDP). The veth's host
#             side fd43:5107::<id>:1 (the slot's v6 gateway) is deprecated,
#             so this host's own connections to the /128 come from its
#             uplink address, not from the gateway.
#   lan       veth on the LAN bridge: a LAN peer like any other, unfiltered.
# Either way inbound from the internet may additionally need an allow rule
# for the slot's v6 address on the routers in front of the LAN (the
# deployment's business).
#
# Enabling this turns the uplink NIC into a port of the bridge; the bridge
# keeps the NIC's MAC and takes over its DHCP/RA config.
#
# Rescue (admin only): reseed a slot with its bootstrap system:
#   rm /nix/var/nix/profiles/per-container/<slot>/system
#   systemctl restart container@<slot>
# (agent slots: `systemctl start agent-slot-reset@<slot>`, ./slots)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.container-slots;
  inherit (lib) mkOption types;

  hex = id: lib.toLower (lib.toHexString id);
  hex2 = id: lib.fixedWidthString 2 "0" (hex id);
  ipv6Of = slot: "${cfg.ipv6Prefix}::5107:${hex slot.id}";
  # The host side of an isolated slot's veth: the slot's v6 gateway.
  # ./slots refuses other agents' packets from fd43:5107::/64.
  hostIPv6Of = slot: "fd43:5107::${hex slot.id}:1";

  isolated = lib.filterAttrs (_: s: s.mode == "isolated") cfg.slots;
  # nspawn names the host side of the veth ve-<name> (routed) or vb-<name>
  # (bridged); the rules below match those names.
  vethOf = name: "ve-${name}";
  isolatedIfs = lib.concatMapStringsSep ", " (n: ''"${vethOf n}"'') (lib.attrNames isolated);
  forwarded = lib.filterAttrs (_: s: s.publicIPv4Ports != [ ]) isolated;
  ports = slot: lib.concatMapStringsSep ", " toString slot.publicIPv4Ports;
  isolatedV6s = lib.concatMapStringsSep ", " ipv6Of (lib.attrValues isolated);

  egress = cfg.isolatedEgress;
  # Where an isolated slot's own connections may leave: the egress
  # interface if there is one, else the bridge (the home uplink).
  outIf = if egress != null then egress.interface else cfg.bridge;
  # fwmark of the packets of connections an isolated slot opened, which the
  # egress rule routes into egress.table. 0x02000000: outside every other
  # mark on the host (checked by an assertion below): the Mullvad app's
  # 0x6d6f6c65, tailscale's 0xff0000 mask and `foreignMarks`. Decimal,
  # which networkd and nft read.
  egressMark = 33554432;
  otherMarks = {
    mullvad-app = 1836018789;
    tailscale = 16711680;
  }
  // cfg.foreignMarks;
  # ", "-prefixed, appended to the always-dropped ranges in isolated-out
  blockedOf = ds: lib.concatMapStrings (d: ", ${d}") ds;
  blocked4 = blockedOf (lib.filter (d: !lib.hasInfix ":" d) cfg.isolatedBlockedDestinations);
  blocked6 = blockedOf (lib.filter (lib.hasInfix ":") cfg.isolatedBlockedDestinations);
  # The slot's own route metrics stay below this, so the unreachable routes
  # only answer while the slot (and its routes) is gone.
  failClosedMetric = 65535;

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

  # The one bootstrap system every slot is seeded with. Nothing slot-specific
  # goes in here (see "Evaluation cost" above): hostName "" keeps the one
  # nspawn sets, root's keys and the host key come from files the host binds
  # in.
  slotKeysPath = "/var/lib/container-slot/authorized_keys";
  slotHostKeyPath = "/var/lib/container-slot/ssh_host_ed25519_key";
  bootstrap =
    (pkgs.nixos {
      boot.isNspawnContainer = true;
      networking.hostName = "";
      services.openssh.enable = true;
      services.openssh.authorizedKeysFiles = [ slotKeysPath ];
      services.openssh.hostKeys = [
        {
          type = "ed25519";
          path = slotHostKeyPath;
        }
      ];
      system.stateVersion = config.system.stateVersion;
    }).toplevel;

  seed =
    name:
    pkgs.writeShellScript "container-slot-seed-${name}" ''
      mkdir -p ${nixStateStub}/{db,daemon-socket,profiles,gcroots}
      if [ ! -e ${profileDir name}/system ]; then
        mkdir -p ${profileDir name}
        ${config.nix.package}/bin/nix-env -p ${profileDir name}/system \
          --set ${bootstrap}
      fi
    '';

  uidBase = slot: 1610612736 + slot.id * 65536;

  shareName = path: lib.removePrefix "-" (lib.replaceStrings [ "/" ] [ "-" ] path);
  slotRun = name: "/run/container-slots/${name}";
  shareMount = name: path: "${slotRun name}/${shareName path}";
  slotKeys = name: "${slotRun name}/authorized_keys";
  slotHostKey = name: "${slotRun name}/ssh_host_ed25519_key";
  # The host-side home of a slot's host key: root's, outside the slot's
  # tree, so no reset or deploy touches it.
  hostKeysDir = "/var/lib/container-slots/host-keys";
  hostKeyDir = name: "${hostKeysDir}/${name}";
  # The slot's /tmp: a host directory instead of nspawn's tmpfs, so it lives
  # wherever the host's /tmp does (e.g. disk, emptied at boot) and not in
  # RAM. Owned by the slot's root; the 0700 parent keeps host users out.
  slotTmp = name: "/tmp/.slots/${name}";
  shareUnit = name: path: "container-slot-${name}-${shareName path}";
  containerRoot = name: "/var/lib/nixos-containers/${name}";

  # Before the slot starts, as host root, with the slot stopped: refuse a
  # root tree with planted symlinks (see "the root tree" above), create the
  # share mount points (owned by the share's account, which fusermount
  # requires), and put the slot's authorized_keys and host key in place
  # (owned by the slot's root, see first boot above). findmnt reads
  # mountinfo only: nothing here may stat a FUSE mount whose NFS source
  # might hang.
  slotPrep =
    name: slot:
    let
      owner = toString (uidBase slot);
      keyDir = hostKeyDir name;
      addresses = lib.concatStringsSep "," (
        lib.optional (slot.mode == "isolated") "10.43.${toString slot.id}.2" ++ [ (ipv6Of slot) ]
      );
    in
    pkgs.writeShellScript "container-slot-prep-${name}" ''
      set -eu
      PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.openssh ]}

      root=${containerRoot name}
      if [ -L "$root" ]; then
        echo "container-slots: ${name}: $root is a symlink, not starting" >&2
        exit 1
      fi
      # Parents first: once a directory is known not to be a link, the
      # next check below it cannot be steered either.
      for p in usr usr/bin etc var var/lib var/lib/private root; do
        if [ -L "$root/$p" ]; then
          echo "container-slots: ${name}: /$p in the slot is a symlink; the start script would follow it as host root. Not starting; reset the slot (hard) to recover." >&2
          exit 1
        fi
      done
      # Replaced by a copy at start anyway; dangling, touch would create
      # its target on this host.
      if [ -L "$root/etc/resolv.conf" ]; then
        rm -f "$root/etc/resolv.conf"
      fi
      if [ -L "$root/etc/machine-id" ]; then
        echo "container-slots: ${name}: removing the /etc/machine-id link" >&2
        rm -f "$root/etc/machine-id"
      fi

      install -d -m 0711 /run/container-slots ${slotRun name}
      install -m 0444 -o ${owner} -g ${owner} \
        ${pkgs.writeText "container-slot-${name}-keys" (lib.concatLines slot.deployKeys)} \
        ${slotKeys name}${lib.optionalString (slot.deployKeyFiles != [ ]) ''

          # Read as root into a file the slot's root reads: only a regular
          # file owned by root, opened without following a link (whoever
          # can write its directory cannot point it at another file).
          for f in ${lib.escapeShellArgs slot.deployKeyFiles}; do
            if [ -L "$f" ] || [ ! -f "$f" ] || [ "$(stat -c %u -- "$f")" != 0 ]; then
              echo "container-slots: ${name}: $f is not a regular file owned by root, not starting" >&2
              exit 1
            fi
            dd if="$f" iflag=nofollow status=none >>${slotKeys name}
          done''}

      install -d -m 0755 /var/lib/container-slots ${hostKeysDir} ${keyDir}
      if [ ! -s ${keyDir}/ssh_host_ed25519_key ] || [ ! -s ${keyDir}/ssh_host_ed25519_key.pub ]; then
        rm -f ${keyDir}/ssh_host_ed25519_key ${keyDir}/ssh_host_ed25519_key.pub
        ssh-keygen -q -t ed25519 -N "" -C ${name} -f ${keyDir}/ssh_host_ed25519_key
      fi
      install -m 0400 -o ${owner} -g ${owner} ${keyDir}/ssh_host_ed25519_key ${slotHostKey name}
      read -r type key _ <${keyDir}/ssh_host_ed25519_key.pub
      echo "${addresses} $type $key" >${keyDir}/known_hosts.new
      chmod 0444 ${keyDir}/known_hosts.new
      mv ${keyDir}/known_hosts.new ${keyDir}/known_hosts

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
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "4G";
        description = "MemoryMax= of container@<slot> (the slot's processes; not its nix builds).";
      };
      memoryLow = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "6G";
        description = ''
          MemoryLow= of container@<slot>: memory the kernel reclaims from
          the slot only after everything unprotected. It protects only as
          far as every ancestor cgroup allows, so machine.slice needs a
          MemoryLow= of its own (systemd.slices.machine).
        '';
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "200%";
        description = "CPUQuota= of container@<slot>.";
      };
      deployKeys = mkOption {
        type = types.listOf types.str;
        default = cfg.deployKeys;
        defaultText = lib.literalExpression "config.services.container-slots.deployKeys";
        description = "SSH keys for root in this slot's bootstrap system (the bind-mounted authorized_keys, see the module header).";
      };
      deployKeyFiles = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Runtime paths of further authorized_keys files for root in this slot's bootstrap system (keys made at runtime), appended to deployKeys at every start. Each must be a regular file owned by root (not a symlink), or the slot does not start.";
      };
      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Start the slot at boot. Off: container@<slot> starts only when something starts it.";
      };
      publicIPv4Ports = mkOption {
        type = types.listOf types.port;
        default = [ ];
        example = [
          14040
          14041
        ];
        description = "TCP ports of the public IPv4 (on `publicIPv4Interface`) DNATed to the same port of this isolated slot.";
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
  options.services.container-slots = {
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
    deployKeys = mkOption {
      type = types.listOf types.str;
      description = "Default `deployKeys` of every slot: root's keys in the bootstrap system a slot starts with. Used only until a slot's first deploy; deployed guests own their keys.";
    };
    hostKeysDir = mkOption {
      type = types.str;
      readOnly = true;
      default = hostKeysDir;
      description = "Where each slot's host key lives on this host: <hostKeysDir>/<slot>/ssh_host_ed25519_key, and known_hosts (the slot's addresses and that key, written at every start; see the module header).";
    };
    isolatedEgress = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            interface = mkOption {
              type = types.str;
              example = "wg-mullvad";
              description = "The only interface isolated slots' own connections may leave through (masqueraded to its addresses).";
            };
            table = mkOption {
              type = types.ints.positive;
              example = 51830;
              description = "Routing table whose default routes (v4 and v6) leave through `interface`.";
            };
          };
        }
      );
      default = null;
      description = ''
        Route every connection an isolated slot opens through `table` and
        drop it on any interface but `interface` (kill switch). null: the
        slots' own connections leave over `bridge`, v4 masqueraded.
        Connections that come in keep answering the way they came.
        Needs a loose reverse-path filter (asserted): the mark is set
        before the firewall's rpfilter runs, so a strict one looks the
        slot's source up in `table`, finds `interface` instead of the
        slot's veth and drops every packet the slot opens.
      '';
    };
    isolatedBlockedDestinations = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "2405:9800:b014::/64" ];
      description = "Extra v4/v6 destinations isolated slots must not reach, beyond the LAN and private ranges (e.g. the routers' WAN side).";
    };
    publicIPv4Interface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wg-v4fwd";
      description = "Link the public IPv4 arrives on; slots' `publicIPv4Ports` are forwarded from it. Whatever brings the address there must route the forwarded connections' replies back the way they came.";
    };
    foreignMarks = mkOption {
      type = types.attrsOf types.int;
      default = { };
      example = {
        ipv4-forward = 268435456;
      };
      description = "Further fwmarks (and masks) in use on this host, by owner, beyond the Mullvad app's and tailscale's; the slots' egress mark 0x02000000 must share no bit with any of them (asserted).";
    };
    bridge = mkOption {
      type = types.str;
      default = "br0";
      description = "LAN bridge that carries the host's own address and the lan slots.";
    };
    lanIPv4 = mkOption {
      type = types.str;
      example = "192.168.8.0/24";
      description = "The LAN's v4 subnet (isolated slots must not reach it).";
    };
    ipv6Prefix = mkOption {
      type = types.str;
      example = "2001:db8:1:2";
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
        message = "services.container-slots.slots.${name}: slot names must be <= 11 chars";
      }) cfg.slots
      ++ lib.mapAttrsToList (name: slot: {
        assertion = lib.count (s: s.id == slot.id) (lib.attrValues cfg.slots) == 1;
        message = "services.container-slots.slots.${name}: id ${toString slot.id} is not unique";
      }) cfg.slots
      ++ lib.mapAttrsToList (name: slot: {
        assertion = slot.publicIPv4Ports == [ ] || (slot.mode == "isolated" && cfg.publicIPv4Interface != null);
        message = "services.container-slots.slots.${name}: publicIPv4Ports need mode isolated and publicIPv4Interface";
      }) cfg.slots
      ++ (
        let
          all = lib.concatMap (s: s.publicIPv4Ports) (lib.attrValues cfg.slots);
        in
        [
          {
            assertion = lib.length all == lib.length (lib.unique all);
            message = "services.container-slots: a publicIPv4Ports port is claimed by more than one slot";
          }
        ]
      )
      ++ lib.mapAttrsToList (owner: mark: {
        assertion = builtins.bitAnd egressMark mark == 0;
        message = "services.container-slots: the slots' egress mark overlaps ${owner}'s fwmark";
      }) otherMarks
      ++ [
        {
          # see isolatedEgress: a strict rpfilter cuts off all slot egress
          assertion =
            egress == null
            || isolated == { }
            || !config.networking.firewall.enable
            || !(lib.elem config.networking.firewall.checkReversePath [
              true
              "strict"
            ]);
          message = "services.container-slots: isolatedEgress needs networking.firewall.checkReversePath = \"loose\" (a strict check drops every packet an isolated slot opens)";
        }
      ];

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
        # While a slot is stopped its host routes are gone; without these
        # its v4 would follow the default route and its v6 the LAN /64 (to
        # whichever LAN peer answers NDP for it). Metric above the
        # container units' own routes, which therefore win while it runs.
        routes = lib.optionals (isolated != { }) (
          [
            {
              Destination = "10.43.0.0/16";
              Type = "unreachable";
              Metric = failClosedMetric;
            }
          ]
          ++ lib.mapAttrsToList (_: slot: {
            Destination = "${ipv6Of slot}/128";
            Type = "unreachable";
            Metric = failClosedMetric;
          }) isolated
        );
        # The slots' own connections (marked in the container-slots nft
        # table) use the egress table. Priority 5000: ahead of the usual
        # meshes' rules (tailscale 5210+), after a deployment's early
        # source rules (e.g. 100, 101). An empty table (tunnel down) falls
        # through to main, where the kill switch drops them.
        routingPolicyRules = lib.optional (egress != null && isolated != { }) {
          FirewallMark = "${toString egressMark}/${toString egressMark}";
          Table = egress.table;
          Priority = 5000;
          Family = "both";
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
    # The initrd (remote unlock) runs networkd on the uplink with DHCP+RA,
    # and by default leaves its addresses and routes in place at switch
    # root. Stage 2 makes the uplink a bare bridge port and, with
    # ManageForeignRoutes off, never removes the leftovers: the initrd's RA
    # route for the LAN /64 on the uplink then competes with the bridge's
    # and wins, so neighbours in that /64 become unreachable (NDP goes out
    # a bridge port). Drop the initrd's config on the uplink when it stops.
    boot.initrd.systemd.network.networks."40-${cfg.uplink}".networkConfig.KeepConfiguration = false;
    networking.networkmanager.unmanaged = [
      "interface-name:${cfg.uplink}"
      "interface-name:${cfg.bridge}"
    ];

    # mkDefault: other modules may set the same value.
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
    boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = lib.mkDefault 1;

    # --- the slots ------------------------------------------------------
    systemd.tmpfiles.rules = [
      "d /tmp/.slots 0700 root root -"
    ]
    ++ lib.mapAttrsToList (
      name: slot: "d ${slotTmp name} 1777 ${toString (uidBase slot)} ${toString (uidBase slot)} -"
    ) cfg.slots;

    containers = lib.mapAttrs (
      name: slot:
      {
        inherit (slot) autoStart;
        privateUsers = uidBase slot;
        privateNetwork = true;
        extraFlags = [
          "--bind-ro=${nixStateStub}:/nix/var/nix"
          # implied by "pick", not by a numeric base: without it the root
          # tree stays host-root-owned, i.e. nobody's inside the slot
          "--private-users-ownership=auto"
          "--bind=${slotTmp name}:/tmp"
        ];
        bindMounts =
          lib.mapAttrs (path: _: {
            hostPath = shareMount name path;
            isReadOnly = false;
          }) slot.shares
          // {
            ${slotKeysPath} = {
              hostPath = slotKeys name;
              isReadOnly = true;
            };
            ${slotHostKeyPath} = {
              hostPath = slotHostKey name;
              isReadOnly = true;
            };
          };
        # No `config`: defining it would make the containers module evaluate
        # a whole NixOS system per slot. Resolved inside the container,
        # where <profileDir> is bind-mounted on /nix/var/nix/profiles: always
        # the slot's current generation.
        path = "/nix/var/nix/profiles/system";
      }
      // (
        if slot.mode == "isolated" then
          {
            hostAddress = "10.43.${toString slot.id}.1";
            localAddress = "10.43.${toString slot.id}.2";
            hostAddress6 = hostIPv6Of slot;
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
          environment.SYSTEMD_NSPAWN_TMPFS_TMP = "0";
          serviceConfig = {
            ExecStartPre = [
              "+${slotPrep name slot}"
              (seed name)
            ];
            # The start script copies the host's /etc/resolv.conf into the
            # slot; in this unit's mount namespace that is the public one.
            BindReadOnlyPaths = [ "${resolvConf}:/etc/resolv.conf" ];
          }
          // lib.optionalAttrs (slot.memoryMax != null) { MemoryMax = slot.memoryMax; }
          // lib.optionalAttrs (slot.memoryLow != null) { MemoryLow = slot.memoryLow; }
          // lib.optionalAttrs (slot.cpuQuota != null) { CPUQuota = slot.cpuQuota; };
          # The veth's host side is the slot's v6 gateway, not an address
          # this host should speak from: the kernel prefers a source on the
          # outgoing interface, so every connection from here to the /128
          # would carry it, and the slot could not tell this host's admin
          # path from anyone else on it (./slots lets other agents
          # reach the /128). Deprecated (preferred_lft 0) it still answers
          # as the gateway, but source selection takes the uplink's global
          # address instead, as for any internet client.
          postStart = lib.mkIf (slot.mode == "isolated") (
            lib.mkAfter ''
              ip -6 addr change ${hostIPv6Of slot}/128 dev ${vethOf name} preferred_lft 0
            ''
          );
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

    programs.fuse.userAllowOther = lib.mkIf (lib.any (s: s.shares != { }) (
      lib.attrValues cfg.slots
    )) true;

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

        ${lib.optionalString (egress != null) ''
          # Packets of connections an isolated slot opened (it sent the
          # first packet: original direction) carry egressMark, which the
          # routing rule sends into the egress table. Its answers to
          # connections that came in are reply-direction and stay unmarked,
          # so they take the main table back out the way they came.
          chain mark-egress {
            type filter hook prerouting priority mangle; policy accept;
            iifname { ${isolatedIfs} } ct direction original meta mark set meta mark or ${toString egressMark}
          }
          # The egress link's MTU (a tunnel) is below the veth's 1500.
          chain egress-mss {
            type filter hook forward priority mangle; policy accept;
            iifname { ${isolatedIfs} } oifname "${egress.interface}" tcp flags syn tcp option maxseg size set rt mtu
          }
        ''}

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
          ${lib.optionalString (egress != null) ''
            # kill switch: the slot's own connections leave through the
            # egress link or not at all, established ones too (a route
            # change mid-connection must not move them to the uplink)
            ct direction original oifname != "${egress.interface}" drop
          ''}
          ct state established,related accept
          oifname != "${outIf}" drop
          ip daddr { ${cfg.lanIPv4}, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16${blocked4} } drop
          ip6 daddr { ${cfg.ipv6Prefix}::/64, fc00::/7, fe80::/10${blocked6} } drop
          accept
        }
        chain isolated-in {
          ct state established,related accept
          ${lib.concatStrings (
            lib.mapAttrsToList (name: slot: ''
              oifname "${vethOf name}" ip6 daddr ${ipv6Of slot} accept
            '') isolated
          )}
          ${lib.concatStrings (lib.mapAttrsToList (name: slot: ''
            iifname "${cfg.publicIPv4Interface}" oifname "${vethOf name}" ip daddr 10.43.${toString slot.id}.2 tcp dport { ${ports slot} } accept
          '') forwarded)}
          drop
        }

        # public IPv4 -> slot, same port; the client's address stays as the
        # source (replies must find their way back, see publicIPv4Interface)
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;
          ${lib.concatStrings (lib.mapAttrsToList (name: slot: ''
            iifname "${cfg.publicIPv4Interface}" tcp dport { ${ports slot} } dnat ip to 10.43.${toString slot.id}.2
          '') forwarded)}
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 10.43.0.0/16 oifname "${outIf}" masquerade
          ${lib.optionalString (egress != null) ''
            ip6 saddr { ${isolatedV6s} } oifname "${outIf}" masquerade
          ''}
        }
      '';
    };
  };
}
