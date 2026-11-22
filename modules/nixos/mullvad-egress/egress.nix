# Selected users reach the internet only through a Mullvad WireGuard tunnel;
# the rest of the host keeps its normal route. Clan wiring and the pinned
# Singapore relays are in ./default.nix; ./test.nix exercises this file.
#
# Routing, after tailscale's rules (5210-5270) so its tailnet stays direct:
#   5999  to <directPrefixes>  lookup main    every user; others use main anyway
#   6000  uid X  lookup main suppress_prefixlength 0
#                              LAN, meshes, ygg: any route but a default
#   6001  uid X  lookup 51830  default dev wg-mullvad, v4 and v6
# networkd removes these rules with the tunnel's link, and the listed users
# then fall through to the main table. The nftables output chain below is
# the kill switch: a listed user's packet to a public address leaves through
# wg-mullvad or is refused, and its DNS (port 53/853) off the tunnel may
# only go to ./dns.nix's 127.0.0.153. Residual: loopback resolvers on other
# ports (hyprspace's 127.43.104.80:11355) stay reachable, which only
# software pointed at them explicitly would use.
#
# `sources` (interfaces, e.g. a container's host-side veth) do the same for
# traffic this host forwards: the same two rules with `iif <interface>`
# instead of `uid X` (6000/6001), and the forward chain is their kill
# switch (public destinations only through wg-mullvad, DNS never off it).
# Their DNS (port 53, to whichever server, this host's stub included) is
# redirected to Mullvad's in-tunnel resolver (./dns.nix's upstream); what
# leaves through the tunnel is masqueraded to its addresses and MSS-clamped
# to its MTU. What this host itself does for such a container stays
# direct: its nix-daemon's fetches (the daemon is root, not a listed user)
# and anything else the container reaches on this host's own addresses
# (local delivery, never forwarded). The packets' interface decides, so a
# container cannot leave the rules by spoofing its source address. The
# routing rules match every forwarded packet from the interface, replies
# included: meant for containers that get no forwarded inbound connections
# (../spaces/host.nix drops them; this host's proxies reach the guest
# locally). A confined space's destination filter lets the redirected DNS
# through (../spaces/host.nix, `ct status dnat`).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.mullvadEgress;
  iface = "wg-mullvad";
  table = 51830;

  uids = map (name: config.users.users.${name}.uid) cfg.users;
  ipv4Prefixes = lib.filter (p: !lib.hasInfix ":" p) cfg.directPrefixes;
  ipv6Prefixes = lib.filter (lib.hasInfix ":") cfg.directPrefixes;

  # Destinations a listed user may still reach off the tunnel: what is never
  # routed to the internet anyway, plus directPrefixes. 200::/7 is
  # yggdrasil.
  direct4 = [
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "255.255.255.255"
  ]
  ++ ipv4Prefixes;
  direct6 = [
    "::1"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
    "200::/7"
  ]
  ++ ipv6Prefixes;

  # The only DNS a tunneled uid may ask off the tunnel: ./dns.nix's unbound.
  tunnelResolver = "127.0.0.153";

  sources = lib.concatMapStringsSep ", " (i: ''"${i}"'') cfg.sources;
  # What a source may reach off the tunnel: direct4/6 without multicast
  # and broadcast, which a container has no business sending through
  # this host (link-local stays: it never leaves the veth anyway).
  forwardDirect4 = lib.subtractLists [ "224.0.0.0/4" "255.255.255.255" ] direct4;
  forwardDirect6 = lib.subtractLists [ "ff00::/8" ] direct6;

  # WireGuard's encrypted packets still carry the sending socket's uid, so
  # the kill switch must let them reach the relays over the uplink.
  relayEndpoints = map (
    r:
    let
      m = builtins.match "([0-9.]+):([0-9]+)" r.endpoint;
    in
    assert lib.assertMsg (m != null) "hyper.mullvadEgress.relays: ${r.endpoint} is not IPv4 host:port";
    "${lib.elemAt m 0} . ${lib.elemAt m 1}"
  ) cfg.relays;

  # tunnelOnly by uid: "<uid>" -> its units' listeners (address:port),
  # for the nftables loopback rule. A unit whose user is not a tunneled
  # one with a uid is the assertion's to report.
  loopbackUids = lib.foldlAttrs (
    acc: name: listeners:
    let
      user = config.systemd.services.${name}.serviceConfig.User or null;
      uid = if user != null then config.users.users.${user}.uid or null else null;
    in
    if uid == null then acc else acc // { ${toString uid} = lib.unique ((acc.${toString uid} or [ ]) ++ listeners); }
  ) { } cfg.tunnelOnly;

  first = lib.head cfg.relays;
  registered = cfg.addresses != [ ];

  failover = pkgs.writeShellApplication {
    name = "mullvad-egress-failover";
    runtimeInputs = [ pkgs.wireguard-tools ];
    text = builtins.readFile ./failover.sh;
  };
in
{
  options.hyper.mullvadEgress = {
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users (static uid required) whose traffic may leave only through the Mullvad tunnel.";
    };
    addresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Tunnel addresses Mullvad assigned to the device. Empty (not yet
        registered): no tunnel, and the users get no internet at all.
      '';
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "WireGuard private key of the registered device, readable by systemd-network.";
    };
    relays = lib.mkOption {
      type = lib.types.nonEmptyListOf (
        lib.types.submodule {
          options = {
            endpoint = lib.mkOption {
              type = lib.types.str;
              description = "host:port";
            };
            publicKey = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      description = "Relays in failover order; the first is used at boot.";
    };
    directPrefixes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Public prefixes the users reach directly, bypassing the tunnel.";
    };
    sources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ve-agave-host" ];
      description = ''
        Container host-side veths (`ve-*`) whose forwarded traffic
        may leave only through the tunnel, its DNS redirected to Mullvad's
        resolver (see the header). This host's own connections on their
        behalf (nix-daemon fetches) stay direct.
      '';
    };
    tunnelOnly = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        searx = [ "127.0.0.1:8890" ];
      };
      description = ''
        System units of tunneled users that may reach nothing off the
        tunnel but their own loopback listeners, given as IPv4
        `address:port` (and the tunnel's DNS, ./dns.nix). Two layers:
        - the unit's cgroup: IPAddressDeny on every direct destination
          above (LAN, meshes, the rest of loopback, directPrefixes),
          IPAddressAllow the listed addresses; it checks the remote
          address both ways, so a peer on loopback must connect from a
          listed address too;
        - nftables, by the unit's uid (every process of that user, in the
          unit or not; table mullvad-egress-loopback): on `lo` it may
          open connections only to the listed address:port pairs and to
          the tunnel's DNS (127.0.0.153:53); replies of established
          connections pass (the listener answering its clients); every
          other new connection over `lo` (other loopback services, other
          ports on a listed address, the host's own non-loopback
          addresses) is dropped.
        So the unit reaches only the internet, through the tunnel, its own
        listeners and the tunnel's DNS. Connections *to* the listeners
        are not limited by this (clients send their own packets); who may
        connect is the listener's own gate.
      '';
    };
  };

  config = lib.mkIf (cfg.users != [ ] || cfg.sources != [ ]) (
    lib.mkMerge [
      {
        assertions =
          map (name: {
            assertion = config.users.users ? ${name} && config.users.users.${name}.uid != null;
            message = "hyper.mullvadEgress.users: '${name}' needs a static uid (uid rules and nftables match numbers).";
          }) cfg.users
          ++ map (interface: {
            # a container's host-side veth (nspawn: ve-<name>, IFNAMSIZ)
            assertion = builtins.match "ve-[A-Za-z0-9_.-]+" interface != null && lib.stringLength interface <= 15;
            message = "hyper.mullvadEgress.sources: '${interface}' is not a container veth name (ve-*, at most 15 characters).";
          }) cfg.sources
          ++ lib.mapAttrsToList (name: listeners: {
            assertion =
              lib.elem (config.systemd.services.${name}.serviceConfig.User or null) cfg.users
              && listeners != [ ]
              && lib.all (l: builtins.match "127\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+" l != null) listeners;
            message = "hyper.mullvadEgress.tunnelOnly.${name}: not a unit of a tunneled user, or a listener that is not IPv4 loopback address:port.";
          }) cfg.tunnelOnly;

        systemd.services = lib.mapAttrs (_: listeners: {
          serviceConfig = {
            IPAddressDeny = direct4 ++ direct6;
            IPAddressAllow = lib.unique (map (l: lib.head (lib.splitString ":" l)) listeners);
          };
        }) cfg.tunnelOnly;

        # tunnelOnly's per-port loopback rule (see the option): one chain
        # per uid, on lo only; everything else is the kill switch
        # below and the cgroup filter above. `ct state established`
        # lets the listener answer its clients; conntrack sees lo.
        networking.nftables.tables.mullvad-egress-loopback = lib.mkIf (loopbackUids != { }) {
          family = "inet";
          content = ''
            chain output {
              type filter hook output priority filter; policy accept;
              ${lib.concatMapStringsSep "\n  " (
                uid: ''oifname "lo" meta skuid ${uid} jump uid_${uid}''
              ) (lib.attrNames loopbackUids)}
            }
          ''
          + lib.concatStrings (
            lib.mapAttrsToList (uid: listeners: ''

              chain uid_${uid} {
                ct state established,related accept
                ip daddr . meta l4proto . th dport { ${
                  lib.concatStringsSep ", " (
                    map (
                      l:
                      let
                        p = lib.splitString ":" l;
                      in
                      "${lib.head p} . tcp . ${lib.last p}"
                    ) listeners
                    ++ [
                      "${cfg.dns.address} . udp . 53"
                      "${cfg.dns.address} . tcp . 53"
                    ]
                  )
                } } accept
                counter drop
              }
            '') loopbackUids
          );
        };

        networking.nftables.enable = true;
        networking.nftables.tables.mullvad-egress = {
          family = "inet";
          content = ''
            chain output {
              type filter hook output priority filter; policy accept;
              meta skuid { ${lib.concatMapStringsSep ", " toString uids} } jump tunneled
            }

            chain tunneled {
              # DNS (53, DoT 853) off the tunnel only to ./dns.nix's resolver:
              # resolved's stub (127.0.0.53/54, DNSStubListenerExtra),
              # dnscrypt-proxy (127.0.5.3), the LAN router or tailscale's
              # 100.100.100.100 would answer over the host's path. Before
              # the loopback accept; through wg-mullvad (unbound's own
              # forwards, a tunneled dig @1.1.1.1) is the tunnel, untouched.
              meta l4proto { tcp, udp } th dport { 53, 853 } oifname != "${iface}" ip daddr != ${tunnelResolver} reject with icmpx port-unreachable
              meta l4proto { tcp, udp } th dport { 53, 853 } oifname != "${iface}" meta nfproto ipv6 reject with icmpx port-unreachable
              oifname { "lo", "${iface}" } accept
              ip daddr . udp dport { ${lib.concatStringsSep ", " relayEndpoints} } accept
              ip daddr { ${lib.concatStringsSep ", " direct4} } accept
              ip6 daddr { ${lib.concatStringsSep ", " direct6} } accept
              reject with icmpx no-route
            }
          ''
          + lib.optionalString (cfg.sources != [ ]) ''

            # sources: the forwarded twin of `tunneled`
            chain forward {
              type filter hook forward priority filter; policy accept;
              iifname { ${sources} } jump forwarded
            }

            chain forwarded {
              meta l4proto { tcp, udp } th dport { 53, 853 } oifname != "${iface}" reject with icmpx port-unreachable
              oifname "${iface}" accept
              ip daddr { ${lib.concatStringsSep ", " forwardDirect4} } accept
              ip6 daddr { ${lib.concatStringsSep ", " forwardDirect6} } accept
              reject with icmpx no-route
            }

            # Their DNS, to whatever server, goes to Mullvad's resolver
            # in the tunnel (with the tunnel down, `forwarded` refuses it).
            chain dns-redirect {
              type nat hook prerouting priority dstnat; policy accept;
              iifname { ${sources} } meta nfproto ipv4 meta l4proto { tcp, udp } th dport 53 dnat ip to ${cfg.dns.upstream.v4}
              iifname { ${sources} } meta nfproto ipv6 meta l4proto { tcp, udp } th dport 53 dnat ip6 to ${cfg.dns.upstream.v6}
            }

            chain tunnel-nat {
              type nat hook postrouting priority srcnat; policy accept;
              iifname { ${sources} } oifname "${iface}" masquerade
            }

            # The tunnel's MTU (1380) is below the veth's 1500.
            chain tunnel-mss {
              type filter hook forward priority mangle; policy accept;
              iifname { ${sources} } oifname "${iface}" tcp flags syn tcp option maxseg size set rt mtu
              iifname "${iface}" oifname { ${sources} } tcp flags syn tcp option maxseg size set rt mtu
            }
          '';
        };
      }

      (lib.mkIf registered {
        systemd.network.netdevs."50-${iface}" = {
          netdevConfig = {
            Name = iface;
            Kind = "wireguard";
            # Mullvad's own default: room for PPPoE and an IPv6 outer header.
            MTUBytes = "1380";
          };
          wireguardConfig.PrivateKeyFile = cfg.privateKeyFile;
          wireguardPeers = [
            {
              PublicKey = first.publicKey;
              Endpoint = first.endpoint;
              AllowedIPs = [
                "0.0.0.0/0"
                "::/0"
              ];
              RouteTable = table;
              # Keeps the NAT mapping open and, by forcing a handshake every
              # two minutes, tells the failover timer the relay is alive.
              PersistentKeepalive = 25;
            }
          ];
        };

        systemd.network.networks."50-${iface}" = {
          matchConfig.Name = iface;
          address = cfg.addresses;
          networkConfig.LinkLocalAddressing = "no";
          linkConfig.RequiredForOnline = "no";
          routingPolicyRules =
            map (prefix: {
              To = prefix;
              Table = "main";
              Priority = 5999;
            }) cfg.directPrefixes
            ++ lib.concatMap (uid: [
              {
                User = uid;
                Table = "main";
                SuppressPrefixLength = 0;
                Priority = 6000;
                Family = "both";
              }
              {
                User = uid;
                Table = table;
                Priority = 6001;
                Family = "both";
              }
            ]) uids
            ++ lib.concatMap (interface: [
              {
                IncomingInterface = interface;
                Table = "main";
                SuppressPrefixLength = 0;
                Priority = 6000;
                Family = "both";
              }
              {
                IncomingInterface = interface;
                Table = table;
                Priority = 6001;
                Family = "both";
              }
            ]) cfg.sources;
        };

        # Replies inside the tunnel come from internet addresses that the
        # main table routes elsewhere; strict reverse-path checks (kernel and
        # nixos-fw) would drop them. WireGuard already authenticates them.
        boot.kernel.sysctl."net.ipv4.conf.${iface}.rp_filter" = 2;
        networking.firewall.extraReversePathFilterRules = ''
          iifname "${iface}" accept
        '';

        systemd.services.mullvad-egress-failover = lib.mkIf (lib.length cfg.relays > 1) {
          description = "Switch the Mullvad tunnel to the next relay when the current one is dead";
          after = [ "systemd-networkd.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.escapeShellArgs (
              [
                (lib.getExe failover)
                iface
              ]
              ++ lib.concatMap (r: [
                r.publicKey
                r.endpoint
              ]) cfg.relays
            );
          };
        };
        systemd.timers.mullvad-egress-failover = lib.mkIf (lib.length cfg.relays > 1) {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "3min";
            OnUnitActiveSec = "2min";
          };
        };
      })
    ]
  );
}
