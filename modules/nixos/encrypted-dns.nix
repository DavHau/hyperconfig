# System DNS only ever leaves this machine encrypted: systemd-resolved
# forwards everything to a local dnscrypt-proxy, which speaks DNS-over-HTTPS
# to Quad9. The one plaintext exception is captive-browser, which has to ask
# the hotspot's DHCP-supplied resolver to reach the login page.
#
#   - resolved: the only global server is dnscrypt-proxy, routing domain
#     `~.`, no FallbackDNS. Overlays that register their own per-link DNS
#     with resolved (hyprspace, tailscale MagicDNS, the Mullvad app) keep
#     their routing domains.
#   - `lan` names and 192.168.8.0/24 reverse lookups go to the home
#     router's dnsmasq over zerotier (see homeRouter).
#   - NetworkManager hands no DHCP/RA/VPN DNS to resolved at all (dns=none,
#     systemd-resolved=false): its resolved plugin ignores [global-dns]
#     (nm-dns-systemd-resolved.c update() never reads global_config) and
#     ipv4.ignore-auto-dns cannot be set as a [connection] default. The
#     device still carries the DHCP servers, so `nmcli dev show` (what
#     captive-browser reads) lists them.
#   - networkd uplinks named in `hyper.encryptedDns.networkdUplinks` drop
#     their DHCP/RA DNS too.
#   - nftables output: DNS (53) and DoT/DoQ (853) leave only to loopback,
#     to private ranges on the overlay links, or from sockets of the
#     captive-dns group. dnscrypt-proxy itself talks HTTPS on 443.
#   - nftables forward (routed, e.g. containers behind NAT) and bridge
#     forward (bridged, e.g. lan container slots, which never reach the
#     inet hooks): forwarded DNS (53, 853) only to private destinations
#     (overlays, LAN, a VPN's in-tunnel resolver), anything else is
#     refused and counted.
#   - container slots (hyperhermes container-slots), where enabled: lan
#     slots ask resolved on the bridge (an extra stub on the slots'
#     dns.hostResolverAddress). Isolated slots keep their own
#     dns.nameservers, reached through their egress (som: Mullvad's
#     in-tunnel resolver, set there), never this host's shared cache.
#
# Not covered: the multicast LLMNR/mDNS lookups resolved does on the local
# link, and VLAN-tagged bridged frames (not parsed by the bridge chain).
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.encryptedDns;
  # Declared only where hyperhermes' container-slots module is imported.
  hasSlots = options ? services.container-slots;
  slots = config.services.container-slots;
  slotsOn = hasSlots && slots.enable;

  # Destinations plaintext DNS may still go to: never routed to the
  # internet. ULA (zerotier, hyprspace, wireguard, tailscale, Mullvad),
  # link-local, yggdrasil, retiolum.
  private4 = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10";
  private6 = "fc00::/7, fe80::/10, 200::/7, 42::/16";
  privateSets = ''
    set private4 {
      type ipv4_addr
      flags interval
      elements = { ${private4} }
    }

    set private6 {
      type ipv6_addr
      flags interval
      elements = { ${private6} }
    }
  '';
  # dnscrypt-proxy's listener. Clear of resolved's stubs (127.0.0.53/54),
  # the hostname's 127.0.0.2, mullvad-egress's 127.0.0.153 and WARP's DNS
  # proxy on 127.0.2.2/127.0.2.3.
  listenAddress = "127.0.5.3";

  captiveGroup = "captive-dns";
  captiveGid = 1213;
  captiveWrapper = "captive-browser-proxy";

  # The home router (GL.iNet Beryl, cm-beryl) on the zerotier network
  # zt44xbwxfb: its dnsmasq knows the LAN's DHCP names under `lan` and
  # answers on this address too. Asking it over zerotier keeps the query
  # inside the encrypted overlay (the nftables rule below lets zt* to
  # private addresses through) and works away from home as well.
  homeRouter = "192.168.194.4";
  forwardingRules = pkgs.writeText "dnscrypt-forwarding-rules.txt" ''
    lan ${homeRouter}
    8.168.192.in-addr.arpa ${homeRouter}
  '';

  dnscryptConfig = (pkgs.formats.toml { }).generate "dnscrypt-proxy.toml" {
    listen_addresses = [ "${listenAddress}:53" ];
    server_names = [ "quad9-doh-ip4-port443-filter-pri" ];
    # From https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md
    # (minisign-verified with the list key
    # RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3, list
    # timestamp 1793615770), first stamp of the entry: DoH to
    # 9.9.9.9:443, host dns9.quad9.net, path /dns-query. The stamp carries
    # the IP, which dnscrypt-proxy caches for the host forever
    # (fetchDoHServerInfo), so the server is reached without a lookup.
    #
    # quad9-doh-ip6-port443-filter-pri is left out: dnscrypt-proxy does not
    # retry a failed query on another server, it only raises that server's
    # RTT estimate, so a v6 server picked on a dual-stack network keeps
    # failing queries on the next v4-only or broken-v6 hotspot.
    static.quad9-doh-ip4-port443-filter-pri.stamp =
      "sdns://AgMAAAAAAAAABzkuOS45LjkgsBkgdEu7dsmrBT4B4Ht-BQ5HPSD3n3vqQ1-v5DydJC8SZG5zOS5xdWFkOS5uZXQ6NDQzCi9kbnMtcXVlcnk";
    ipv4_servers = true;
    ipv6_servers = false;
    doh_servers = true;
    dnscrypt_servers = false;
    odoh_servers = false;
    # Quad9 filters; the server is named explicitly anyway.
    require_dnssec = false;
    require_nolog = false;
    require_nofilter = false;
    # No `sources`: the resolver list is never downloaded. No bootstrap
    # resolvers either: they only resolve hosts missing from the IP cache,
    # and the one host there is comes pinned from the stamp.
    bootstrap_resolvers = [ ];
    ignore_system_dns = true;
    # The probe only connect()s a UDP socket, which sends no packet.
    netprobe_address = "9.9.9.9:443";
    netprobe_timeout = 60;
    forwarding_rules = "${forwardingRules}";
  };
in
{
  options.hyper.encryptedDns = {
    captiveInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wlp192s0";
      description = "Interface captive-browser binds to and reads the DHCP DNS of; null leaves captive-browser off.";
    };

    networkdUplinks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "40-br0" ];
      description = "systemd.network.networks entries of uplinks whose DHCP/RA DNS servers and domains are ignored.";
    };
  };

  config = lib.mkMerge [
    {
      services.dnscrypt-proxy = {
        enable = true;
        configFile = dnscryptConfig;
      };

      # resolved's global DNS= defaults to this; the dnscrypt-proxy module
      # would mkDefault it to 127.0.0.1.
      networking.nameservers = [ listenAddress ];

      services.resolved = {
        enable = true;
        settings.Resolve = {
          # `lan` as search domain: bare LAN hostnames (`vit`) resolve as
          # `vit.lan` via forwardingRules.
          Domains = [
            "~."
            "lan"
          ];
          # Empty: resolved's compiled-in fallback servers are plaintext.
          FallbackDNS = [ ];
          # The hop to dnscrypt-proxy is loopback.
          DNSOverTLS = false;
        };
      };

      # mkForce: resolved.nix sets "systemd-resolved".
      networking.networkmanager.dns = lib.mkForce "none";
      networking.networkmanager.settings.main.systemd-resolved = false;

      systemd.network.networks = lib.genAttrs cfg.networkdUplinks (_: {
        dhcpV4Config = {
          UseDNS = false;
          UseDomains = false;
        };
        dhcpV6Config = {
          UseDNS = false;
          UseDomains = false;
        };
        ipv6AcceptRAConfig = {
          UseDNS = false;
          UseDomains = false;
        };
      });

      users.groups.${captiveGroup}.gid = captiveGid;

      networking.nftables.enable = true;
      networking.nftables.tables.encrypted-dns = {
        family = "inet";
        content =
          let
            # Overlays whose resolvers sit inside the overlay. Their DNS is
            # let through only towards private destinations, so an exit
            # node or a VPN default route cannot carry plaintext DNS to the
            # internet.
            overlayInterfaces = [
              "zt*" # zerotier
              "ygg" # yggdrasil
              "tinc.retiolum" # retiolum
              "wg-*" # clan wireguard (wg-edi, wg-vault, ...), mullvad-egress's wg-mullvad (10.64.0.1)
              "wg0-mullvad" # Mullvad app: its in-tunnel resolver 10.64.0.1 / fc00:bbbb:bbbb:bb01::1
              "hyprspace" # its resolver itself listens on loopback (127.43.104.80:11355)
              "tailscale0" # MagicDNS 100.100.100.100 / fd7a:115c:a1e0::53
            ];
          in
          ''
            ${privateSets}

            chain output {
              type filter hook output priority filter; policy accept;
              meta l4proto { tcp, udp } th dport { 53, 853 } jump dns
            }

            chain dns {
              # Loopback, also covering the machine's own addresses:
              # dnscrypt-proxy, resolved's stubs, hyprspace's resolver,
              # mullvad-egress's unbound, WARP's DNS proxy.
              oifname "lo" accept
              # captive-browser's proxy, setgid ${captiveGroup}.
              meta skgid ${toString captiveGid} accept
              ${lib.concatMapStringsSep "\n  " (
                i: ''oifname "${i}" ip daddr @private4 accept'' + "\n  " + ''oifname "${i}" ip6 daddr @private6 accept''
              ) overlayInterfaces}
              counter reject with icmpx admin-prohibited
            }

            # Routed traffic of containers and VMs with a resolver of their
            # own. Private destinations stay allowed (a VPN's in-tunnel
            # resolver, e.g. the isolated container slots' Mullvad
            # 10.64.0.1, the LAN, the overlays). A base chain of its own:
            # its reject is final whatever nixos-fw's forward chain says.
            chain forward {
              type filter hook forward priority filter; policy accept;
              meta l4proto { tcp, udp } th dport { 53, 853 } jump forward-dns
            }

            chain forward-dns {
              ip daddr @private4 accept
              ip6 daddr @private6 accept
              counter reject with icmpx admin-prohibited
            }
          '';
      };

      # Bridged frames (e.g. lan container slots on the uplink bridge) pass
      # no inet hook. Drop, not reject: the bridge family rejects only in
      # prerouting and input.
      networking.nftables.tables.encrypted-dns-bridge = {
        family = "bridge";
        content = ''
          ${privateSets}

          chain forward {
            type filter hook forward priority filter; policy accept;
            meta l4proto { tcp, udp } th dport { 53, 853 } jump dns
          }

          chain dns {
            ip daddr @private4 accept
            ip6 daddr @private6 accept
            ${lib.optionalString slotsOn "ip6 daddr ${slots.ipv6Prefix}::/64 accept # the slots' LAN /64: global, but the LAN's own"}
            counter drop
          }
        '';
      };
    }

    # lan container slots ask resolved over the bridge (their resolv.conf
    # names dns.hostResolverAddress; container-slots puts that address on
    # the bridge and opens port 53 on it to the lan slots). resolved binds
    # extra stubs with IP_FREEBIND, so the address need not exist yet.
    (lib.optionalAttrs hasSlots {
      services.container-slots.dns.lanHostResolver = true;
    })
    (lib.mkIf slotsOn {
      services.resolved.settings.Resolve.DNSStubListenerExtra = [ slots.dns.hostResolverAddress ];
    })

    (lib.mkIf (cfg.captiveInterface != null) {
      programs.captive-browser = {
        enable = true;
        interface = cfg.captiveInterface;
        # The module runs `${package}/bin/captive-browser`; point that at the
        # setgid wrapper, so the proxy's sockets (and the DHCP-DNS lookups
        # among them) carry the captive-dns gid nftables lets through.
        # /bin/sh is bash, which drops the egid again for the dhcp-dns
        # command and the browser it starts. bind-device needs no
        # capability: an unprivileged SO_BINDTODEVICE only fails on a
        # socket already bound to a device (sock_bindtoindex_locked).
        package = pkgs.runCommand "captive-browser-setgid" { } ''
          mkdir -p $out/bin
          ln -s ${config.security.wrapperDir}/${captiveWrapper} $out/bin/captive-browser
        '';
      };

      security.wrappers.${captiveWrapper} = {
        source = "${pkgs.captive-browser}/bin/captive-browser";
        owner = "root";
        group = captiveGroup;
        setuid = false;
        setgid = true;
      };
    })
  ];
}
