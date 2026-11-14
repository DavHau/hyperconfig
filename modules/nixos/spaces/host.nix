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
      ../hermes-desktop-spaces.nix).
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
    - The guest's home at homeDir here, read-write.
    - `tpm`: /dev/tpmrm0 bound in, a POSIX ACL for the guest's uid set at
      every container start.
    - `credentials` (name -> host path, the ssh host key's included) as
      systemd credentials (nspawn --load-credential), copied in at start.
    - `hostNixDaemon` false (../hermes-desktop-spaces.nix): the guest gets
      no way to this host's nix-daemon. nixos-containers binds the
      daemon's socket directory into every container; this host's daemon
      builds (fixed-output derivations: with network) in this host's
      network namespace and hands builds to its build machines, so a guest
      user who can talk to it is past `confine`. nspawn's
      --inaccessible over that directory (it sorts after the module's
      bind of the same path, so it wins) and nix.enable = false in the
      guest. The store stays bound read-only, the guest runs from it.

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
  guestConfig,
  specialArgs,
  toGuestRules ? "",
  confine ? false,
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
  containerConf =
    config.environment.etc."nixos-containers/${name}.conf"
      or config.environment.etc."containers/${name}.conf";
  bracket = address: if lib.hasInfix ":" address then "[${address}]" else address;
  set = list: "{ ${lib.concatStringsSep ", " list} }";
  ssh = sshPort != null;

  # The named spaces: no mesh, no LAN, and of this host DNS only.
  confinement = ''

    chain confine-forward {
      type filter hook forward priority filter; policy accept;
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
    "d ${stateDir} 0755 root root -"
    "d ${homeDir} 0700 ${toString uid} ${toString uid} -"
  ];

  assertions = [
    {
      assertion = !ssh || lib.all (v: v != null) [ address meshInterface proxyUser proxyUid ];
      message = "spaces/host.nix: ${name} has an sshPort, so it needs address, meshInterface, proxyUser and proxyUid too";
    }
  ];

  containers.${name} = {
    autoStart = true;
    # Also the bound of a reload, the guest's switch in place (below),
    # which waits for the guest's units it restarts to stop and start.
    timeoutStartSec = "5min";
    privateNetwork = true;
    inherit
      hostAddress
      localAddress
      hostAddress6
      localAddress6
      ;
    bindMounts.${guestHome} = {
      hostPath = homeDir;
      isReadOnly = false;
    };
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
      ++ lib.optional (!hostNixDaemon) "--inaccessible=/nix/var/nix/daemon-socket";
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
        ${pkgs.acl}/bin/setfacl -m u:${toString uid}:rw /dev/tpmrm0
      ''
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
