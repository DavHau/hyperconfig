/*
  The host side of one space container: a function from the space's
  parameters to the host's configuration for it, shared by infra-space
  (../infra-space/default.nix, whose header explains every part) and the
  named spaces (./default.nix, hyper.spaces.<name>).

    - containers.<name>: private veth ve-<name>, the guest at localAddress
      / localAddress6, this host at hostAddress / hostAddress6, everything
      the guest sends out masqueraded (networking.nat).
    - DNS from this host's resolved through an extra stub on hostAddress.
    - The guest's sshd at [address]:sshPort only (a socket-activated
      systemd-socket-proxyd as its own uid, opened on meshInterface).
      sshPort null: no forward, no proxy user (a guest nobody logs into,
      ../dave-desktop/isolated-apps.nix).
    - nftables table <name>: no new forwarded connection into the veth;
      on this host only root, the proxy (port 22) and `toGuestRules` reach
      the guest.
    - `confine` (the named spaces, not infra-space): the guest is no fleet
      member. Its forwarded traffic to private and mesh ranges
      (`blockedDestinations`: yggdrasil, ULA, RFC 1918, CGNAT, link-local,
      retiolum) is dropped, so it reaches the internet but neither the
      fleet over this host's mesh address nor the LANs this host is on;
      and of this host it reaches DNS on hostAddress only (no sshd, no
      other space's or infra-space's ssh proxy, no other host service).
      `siblingForwards` ({ address, port } each) are the exceptions: the
      ssh forwards of the same space's copies on its other machines
      (./default.nix), accepted before the rejects, that port only.
    - The guest's home at homeDir here, read-write.
    - `tpm`: /dev/tpmrm0 bound in, a POSIX ACL for the guest's uid set at
      every container start.
    - `credentials` (name -> host path, the ssh host key's included) as
      systemd credentials (nspawn --load-credential), copied in at start.
    - `hostNixDaemon` false (../dave-desktop/isolated-apps.nix): the guest gets
      no way to this host's nix-daemon. nixos-containers binds the
      daemon's socket directory into every container; this host's daemon
      builds (fixed-output derivations: with network) in this host's
      network namespace and hands builds to its build machines, so a guest
      user who can talk to it is past `confine`. nspawn's
      --inaccessible over that directory (it sorts after the module's
      bind of the same path, so it wins) and nix.enable = false in the
      guest. The store stays bound read-only, the guest runs from it.
    - `privateUsers` (default on): the guest runs in its own user
      namespace, container uid n = host uid uidBase + n (uidBase:
      0x50000000 + 0x10000 * the veth slot, see `uidBase` below; the
      hermes slots have 0x60000000 up). So its root, like its users, is
      an unprivileged uid here and an untrusted client of this host's
      nix-daemon (Dave: no container may inject store paths; with it off
      the guest's root is host uid 0, which the daemon trusts). Nothing on
      disk moves: the root tree keeps its owners and nspawn idmaps it
      (--private-users-ownership=map; zfs >= 2.2 and ext4 have idmapped
      mounts; on a file system without them nspawn refuses to start
      rather than chown the tree, which would end the rollback), and so are
      the home (homeDir, idmapped bind) and the module's store, db,
      socket, profiles and gcroots binds; turning it off again is the
      rollback. What changes for the guest: its root holds capabilities
      in its own namespace only (no CAP_LINUX_IMMUTABLE: `immutableHelper`
      below; no host devices but those bound in; `machinectl bind` is
      refused, so binds are set at start). Because its root no longer is
      this host's, the start script (nixpkgs, as host root) must not
      follow links it planted in its tree: the prep step refuses them
      (as hyperhermes' container slots do).
      The guest's root creates files owned by this host's uid 0 (in its
      tree and, idmapped, in its home), so a setuid binary or a file
      capability it plants would be root's here. Two locks: the parents
      of every container's tree and of every home (stateDir and the
      directory above it, nixos-containers' directory, the per-container
      profiles and gcroots) are 0700 root, so no host user reaches one;
      and the home, like the per-container profiles and gcroots, is a
      nosuid,nodev bind of itself here (set before every start), which
      the guest's bind inherits, so nothing in them runs setuid or with
      file capabilities, here or in the guest.
      Rollback (privateUsers = false): the 0700 parents, the nosuid binds
      and the start-time binds stay, no bind is idmapped any more (an
      assertion below), and on-disk owners were never changed (map
      refuses rather than chowns, above), so
      `stat -c %u /var/lib/{nixos-,}containers/<name>` is still 0.
    - `immutableHelper` (null, or a directory of the guest or a list of
      them: hermes' locked homes): /run/space-immutable/<name>/socket in the guest at
      /run/space-immutable/socket (./immutable-helper.py): the guest's
      root sends a descriptor of a file or directory directly in one of
      those directories, one of its own root's, and gets the immutable flag set
      or cleared on it (hermes' lockedConfig pins, hyperhermes'
      locked-pins.py).

  A change of the guest alone switches it in place (reload); anything on
  this side restarts it (../infra-space/default.nix has the details).
  The ssh forward never starts the container (PartOf=, no Requires=): a
  client reconnecting while a switch has it stopped would start it from
  the old unit and the old .conf, booting the old guest.
*/
{
  config,
  lib,
  pkgs,
}:
{
  name,
  uid,
  proxyUser ? null,
  proxyUid ? null,
  hostAddress,
  localAddress,
  hostAddress6,
  localAddress6,
  stateDir,
  homeDir,
  guestHome,
  address ? null,
  sshPort ? null,
  meshInterface ? null,
  tpm,
  credentials,
  hostNixDaemon ? true,
  privateUsers ? true,
  immutableHelper ? null,
  guestConfig,
  specialArgs,
  toGuestRules ? "",
  confine ? false,
  siblingForwards ? [ ],
  blockedDestinations ? {
    v4 = [ ];
    v6 = [ ];
  },
}:
let
  # nspawn's host-side veth: ve-<name>, at most 15 characters.
  veth = "ve-${name}";
  # The containers module's /etc/<prefix>containers/<name>.conf; its
  # prefix is `nixos-` or none, by stateVersion.
  prefix = if config.environment.etc ? "nixos-containers/${name}.conf" then "nixos-" else "";
  containerConf = config.environment.etc."${prefix}containers/${name}.conf";
  stateDirectory = "/var/lib/${prefix}containers";
  bracket = address: if lib.hasInfix ":" address then "[${address}]" else address;
  set = list: "{ ${lib.concatStringsSep ", " list} }";
  ssh = sshPort != null;

  # The guest's uid 0 here: one 64k range per veth slot (10.235.<a>.<4i+2>:
  # 64a + i), below the hermes slots' 0x60000000.
  octets = map lib.toInt (lib.splitString "." localAddress);
  slot = lib.elemAt octets 2 * 64 + lib.elemAt octets 3 / 4;
  uidBase = 1342177280 + slot * 65536;
  hostUid = guestUid: if privateUsers then uidBase + guestUid else guestUid;
  containerRoot = "${stateDirectory}/${name}";
  immutableDir = "/run/space-immutable/${name}";
  idmap = lib.optionalString privateUsers ":idmap";
  # without its own user namespace the guest's root sets the flag itself
  helper = immutableHelper != null && privateUsers;

  # Before every start, as host root, the guest stopped: nixpkgs' start
  # script then works in the guest's tree (mkdir -p, chmod, touch, cp) and
  # follows links; with its own root the guest could have replaced
  # /root by a link to this host's /. Parents first, so no check below
  # one already done can be steered (hyperhermes/modules/container-slots.nix).
  prep = pkgs.writeShellScript "space-prep-${name}" ''
    set -eu
    root=${containerRoot}
    [ -e "$root" ] || exit 0
    if [ -L "$root" ]; then
      echo "spaces: ${name}: $root is a symlink, not starting" >&2
      exit 1
    fi
    for p in usr usr/bin etc var var/lib var/lib/private root; do
      if [ -L "$root/$p" ]; then
        echo "spaces: ${name}: /$p in the guest is a symlink; the start script would follow it as host root. Not starting." >&2
        exit 1
      fi
    done
    [ ! -L "$root/etc/resolv.conf" ] || rm -f "$root/etc/resolv.conf"
    [ ! -L "$root/etc/machine-id" ] || rm -f "$root/etc/machine-id"
  '';

  # Before every start, as host root: the home and the per-container
  # profiles and gcroots (the guest's root writes in all three), each a
  # nosuid,nodev bind of itself here (see privateUsers in the header).
  # nspawn's bind of them into the guest copies those flags, and in the
  # guest's user namespace they are locked (the guest's root cannot
  # remount them away). The unit has no mount namespace of its own: the
  # mounts are this host's and stay across restarts; a second start only
  # checks them. Their parents are root's 0700, so the guest cannot swap
  # one for a link. Profiles hold links only, nosuid changes nothing for
  # the guest's switches.
  homeMount = pkgs.writeShellScript "space-home-${name}" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux ]}
    home=${homeDir}
    if [ -L "$home" ] || [ -L ${stateDir} ]; then
      echo "spaces: ${name}: $home or ${stateDir} is a symlink, not starting" >&2
      exit 1
    fi
    [ -d "$home" ] || install -d -m 0700 -o ${toString uid} -g ${toString uid} "$home"
    for d in /nix/var/nix/profiles/per-container/${name} /nix/var/nix/gcroots/per-container/${name}; do
      if [ -L "$d" ]; then
        echo "spaces: ${name}: $d is a symlink, not starting" >&2
        exit 1
      fi
      # as nixpkgs' start script would create them, a moment later
      [ -d "$d" ] || install -d -m 0755 "$d"
    done
    # These self-binds are host mounts that outlive the container; after a
    # space is dropped from the config they stay until reboot (rm -r of
    # its dirs gives EBUSY until `umount` of each).
    for d in "$home" /nix/var/nix/profiles/per-container/${name} /nix/var/nix/gcroots/per-container/${name}; do
      if ! mountpoint -q "$d"; then
        mount --bind "$d" "$d"
      fi
      opts=",$(findmnt -n -o VFS-OPTIONS --mountpoint "$d" | tail -n 1),"
      case "$opts" in
        *,nosuid,*) case "$opts" in *,nodev,*) continue ;; esac ;;
      esac
      mount -o remount,bind,nosuid,nodev "$d"
    done
  '';

  immutableHelperScript = pkgs.writers.writePython3 "space-immutable-helper" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./immutable-helper.py);

  # The named spaces: no mesh, no LAN, and of this host DNS only.
  confinement = ''

    chain confine-forward {
      type filter hook forward priority filter; policy accept;
      ${lib.concatMapStrings (
        f:
        ''iifname "${veth}" ${if lib.hasInfix ":" f.address then "ip6" else "ip"} daddr ${f.address} tcp dport ${toString f.port} accept
        ''
      ) siblingForwards}
      ${lib.optionalString (lib.elem veth (config.hyper.mullvadEgress.sources or [ ])) ''
        # DNS this host redirected (../mullvad-egress `sources`: Mullvad's
        # in-tunnel resolver, a private address)
        iifname "${veth}" ct status dnat meta l4proto { tcp, udp } th dport 53 return''}
      ${lib.optionalString (blockedDestinations.v4 != [ ]) ''iifname "${veth}" ip daddr ${set blockedDestinations.v4} reject with icmpx admin-prohibited''}
      ${lib.optionalString (blockedDestinations.v6 != [ ]) ''iifname "${veth}" ip6 daddr ${set blockedDestinations.v6} reject with icmpx admin-prohibited''}
    }
    chain confine-input {
      type filter hook input priority filter; policy accept;
      iifname "${veth}" ip daddr ${hostAddress} meta l4proto { tcp, udp } th dport 53 accept
      iifname "${veth}" ip6 daddr ${hostAddress6} meta l4proto { tcp, udp } th dport 53 accept
      iifname "${veth}" ct state new meta l4proto tcp reject with tcp reset
      iifname "${veth}" ct state new meta l4proto != { icmp, ipv6-icmp } reject with icmpx admin-prohibited
    }
  '';
in
lib.mkMerge [
{
  systemd.tmpfiles.rules = [
    "d ${homeDir} 0700 ${toString uid} ${toString uid} -"
  ];
  # see privateUsers in the header: no host user reaches into a tree or
  # a home whose files the guest's root creates (nixpkgs leaves the
  # first three 0755); one entry each for all spaces (equal definitions
  # merge). Only root walks into them here: the container units, the
  # space-gui and gcroot helpers, the backup.
  systemd.tmpfiles.settings.spaces = lib.genAttrs (
    [
      stateDirectory
      "/nix/var/nix/profiles/per-container"
      "/nix/var/nix/gcroots/per-container"
      stateDir
    ]
    # /var/lib/spaces, /var/lib/hermes-desktop-spaces; not /var/lib
    ++ lib.optional (dirOf stateDir != "/var/lib") (dirOf stateDir)
  ) (_: {
    d = {
      mode = "0700";
      user = "root";
      group = "root";
    };
  });

  assertions = [
    {
      assertion = !ssh || lib.all (v: v != null) [ address meshInterface proxyUser proxyUid ];
      message = "spaces/host.nix: ${name} has an sshPort, so it needs address, meshInterface, proxyUser and proxyUid too";
    }
    {
      # 4096 slots of 0x10000 from 0x50000000 end at 0x60000000, where
      # hyperhermes' container slots start: a third octet above 63 would
      # overlap their ranges
      assertion = !privateUsers || (lib.length octets == 4 && slot < 4096);
      message = "spaces/host.nix: ${name}: no uid range for localAddress ${localAddress}";
    }
    {
      # rollback: the guest's root is this host's again, an idmapped bind
      # would map nothing (nspawn refuses it) or the wrong range
      assertion = privateUsers || !lib.any (lib.hasInfix ":idmap") config.containers.${name}.extraFlags;
      message = "spaces/host.nix: ${name}: privateUsers is off, but a bind of containers.${name}.extraFlags is still idmapped";
    }
  ];

  containers.${name} = {
    autoStart = true;
    # Also the bound of a reload, the guest's switch in place (below),
    # which waits for the guest's units it restarts to stop and start.
    timeoutStartSec = "5min";
    privateNetwork = true;
    privateUsers = if privateUsers then uidBase else "no";
    inherit
      hostAddress
      localAddress
      hostAddress6
      localAddress6
      ;
    # The TPM for the guest's age identity; access: the ACL below.
    bindMounts."/dev/tpmrm0" = lib.mkIf tpm {
      hostPath = "/dev/tpmrm0";
      isReadOnly = false;
    };
    allowedDevices = lib.mkIf tpm [
      {
        node = "/dev/tpmrm0";
        modifier = "rw";
      }
    ];
    extraFlags =
      lib.mapAttrsToList (n: path: "--load-credential=${n}:${path}") credentials
      ++ lib.optional (!hostNixDaemon) "--inaccessible=/nix/var/nix/daemon-socket"
      ++ lib.optionals privateUsers [
        # implied by "pick", not by a numeric base: without it the tree
        # stays host-owned, i.e. nobody's in the guest. "map", not
        # "auto": where the file system has no idmapped mounts, auto
        # falls back to chowning the whole tree (no rollback then);
        # map refuses to start instead.
        "--private-users-ownership=map"
      ]
      # the home keeps its owner: idmapped (bindMounts has no options);
      # nosuid,nodev from its bind here (homeMount)
      ++ [ "--bind=${homeDir}:${guestHome}${idmap}" ]
      ++ lib.optional helper "--bind-ro=${immutableDir}:/run/space-immutable:idmap";
    inherit specialArgs;
    config =
      if hostNixDaemon then
        guestConfig
      else
        {
          imports = [ guestConfig ];
          nix.enable = false;
        };
  };

  networking.nat = {
    enable = true;
    enableIPv6 = true;
    internalInterfaces = [ veth ];
  };

  # Up the moment it exists, and kept away from systemd-networkd
  # (../infra-space/default.nix has why).
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="${veth}", RUN+="${pkgs.iproute2}/bin/ip link set dev $name up"
  '';
  systemd.network.networks."10-${veth}" = lib.mkIf config.systemd.network.enable {
    matchConfig.Name = veth;
    linkConfig.Unmanaged = true;
  };
  # The guest's toplevel reloads (switches it in place), everything else
  # in the container's .conf restarts it (../infra-space/default.nix).
  systemd.services."container@${name}" = {
    restartTriggers = lib.mkForce [
      (builtins.unsafeDiscardStringContext (
        lib.concatStringsSep "\n" (
          lib.filter (line: !lib.hasPrefix "SYSTEM_PATH=" line) (
            lib.splitString "\n" containerConf.text
          )
        )
      ))
    ];
    reloadTriggers = [ config.containers.${name}.path ];
    # The bind mount needs the TPM node, and the guest's user the ACL on
    # it, set at each start (../infra-space/default.nix).
    requires = lib.mkIf tpm [ "dev-tpmrm0.device" ];
    after = lib.mkIf tpm [ "dev-tpmrm0.device" ];
    preStart = lib.mkIf tpm (
      lib.mkAfter ''
        ${pkgs.acl}/bin/setfacl -m u:${toString (hostUid uid)}:rw /dev/tpmrm0
      ''
    );
    serviceConfig.ExecStartPre = lib.mkBefore (
      lib.optional privateUsers "+${prep}" ++ [ "+${homeMount}" ]
    );
    postStart = lib.mkAfter ''
      ip route replace ${localAddress} dev ${veth} src ${hostAddress}
      # a source only once its duplicate address detection is over
      for _ in {1..100}; do
        [ -z "$(ip -6 addr show dev ${veth} to ${hostAddress6} tentative)" ] && break
        sleep 0.1
      done
      ip -6 route replace ${localAddress6} dev ${veth} src ${hostAddress6}
    '';
  };

  # Only this host opens connections into the guest, and on this host
  # only root and the forwarders; the guest's own connections and their
  # replies pass (see the header).
  networking.nftables.enable = true;
  networking.nftables.tables.${name} = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority filter; policy accept;
        oifname "${veth}" ct state new drop
      }
      # Every packet a local socket sends in the original direction, not
      # only a flow's first (two UDP sockets with SO_REUSEADDR share a
      # port whatever their uid). Socketless packets never match skuid.
      chain output {
        type filter hook output priority filter; policy accept;
        oifname "${veth}" ct direction original jump to-guest
      }
      chain to-guest {
        meta skuid 0 return
        ${lib.optionalString ssh "meta skuid ${toString proxyUid} tcp dport 22 return"}
        ${toGuestRules}
        meta skuid != 0 jump refuse
      }
      chain refuse {
        meta l4proto tcp reject with tcp reset
        reject with icmpx admin-prohibited
      }
    ''
    + lib.optionalString confine confinement;
  };

  services.resolved.settings.Resolve.DNSStubListenerExtra = lib.mkIf config.services.resolved.enable [
    hostAddress
  ];
  networking.firewall.interfaces.${veth} = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ];
  };

}
# The guest's root sets and clears the immutable flag of its own files.
(lib.mkIf helper {
  systemd.sockets."space-immutable-${name}" = {
    description = "Immutable flags for the ${name} guest's root";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${immutableDir}/socket" ];
    socketConfig = {
      Accept = true;
      SocketMode = "0600";
      DirectoryMode = "0700";
      MaxConnections = 4;
      TriggerLimitIntervalSec = 0;
    };
  };
  systemd.services."space-immutable-${name}@" = {
    description = "Set an immutable flag for the ${name} guest";
    path = [ config.systemd.package ];
    environment = {
      SPACE_NAME = name;
      SPACE_UID_BASE = toString uidBase;
      SPACE_ROOT = containerRoot;
      # the guest's paths of the only directories whose entries it may flag
      SPACE_IMMUTABLE_DIR = lib.concatStringsSep ":" (lib.toList immutableHelper);
    };
    serviceConfig = {
      ExecStart = immutableHelperScript;
      StandardInput = "socket";
      StandardOutput = "journal";
      RuntimeMaxSec = "1min";
      ProtectSystem = "strict";
      PrivateNetwork = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      NoNewPrivileges = true;
      # the flag, on a file of another owner (the guest root's); the walk
      # into the guest's 0700 directories (immutable-helper.py in_dir)
      CapabilityBoundingSet = [
        "CAP_LINUX_IMMUTABLE"
        "CAP_FOWNER"
        "CAP_DAC_READ_SEARCH"
      ];
    };
  };
  systemd.services."container@${name}" = {
    wants = [ "space-immutable-${name}.socket" ];
    after = [ "space-immutable-${name}.socket" ];
  };
})
# The ssh forward, its proxy user and port.
(lib.mkIf ssh {
  systemd.sockets."${name}-ssh" = {
    description = "${name} sshd on the mesh address";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${bracket address}:${toString sshPort}" ];
    socketConfig.FreeBind = true;
  };
  systemd.services."${name}-ssh" = {
    description = "Forward to the ${name} container's sshd";
    # Never starts the container: a connection while a switch restarts
    # it (between its stop and the daemon-reload) would start it from the
    # old unit and the old .conf, i.e. boot the old guest, and the
    # switch's own start would then find it running. Until the container
    # is up a connection is refused; its stop ends the forwarded ones.
    partOf = [ "container@${name}.service" ];
    after = [ "container@${name}.service" ];
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${localAddress}:22";
      # the static user below, still with DynamicUser's sandbox
      DynamicUser = true;
      User = proxyUser;
      Group = proxyUser;
      PrivateTmp = true;
    };
  };
  users.users.${proxyUser} = {
    isSystemUser = true;
    uid = proxyUid;
    group = proxyUser;
  };
  users.groups.${proxyUser}.gid = proxyUid;
  networking.firewall.interfaces.${meshInterface}.allowedTCPPorts = [ sshPort ];
})
]
