# Global IPv6 for a roaming client (amy) on IPv4-only networks, through a
# gateway with native IPv6 (som), carried over yggdrasil.
#
# Transport: an ip6ip6 tunnel between the two machines' yggdrasil
# addresses (`v6fb` on the client, `v6fb-<client>` on the gateway). A
# yggdrasil address is bound to its machine's key, so a packet from it
# really comes from that machine; yggdrasil itself already works where
# UDP is blocked (TCP/TLS peers). Point-to-point ULA fd99:6fb:0:<index>::/64
# (::1 gateway, ::2 client). The gateway forwards only the client's own
# tunnel address, only to global unicast (2000::/3 minus the home LAN's
# public prefixes), only out of its uplink, masqueraded to its uplink
# address (NAT66: the client's v6 traffic leaves from the gateway's
# address); inbound only replies.
#
# Client routing never puts a global route into the main table. The
# 2000::/3 route lives in its own table, consulted by an ip rule AFTER
# main (priority 32800) only for:
#   - sockets of local users (uid range, default 1000-29999), and
#   - packets forwarded from the container veths (`forwardInterfaces`),
#     marked in prerouting (see `mark`).
# So:
#   - Overlay daemons never enter the tunnel: kernel WireGuard, zerotier,
#     tailscale, hyprspace run as root and yggdrasil as a DynamicUser
#     (uid >= 61184), outside the range. Their underlay traffic to public
#     v6 endpoints keeps failing as before ("no route") instead of looping
#     into a tunnel that itself rides yggdrasil (the loop that took amy
#     off the mesh with the first, main-table hotfix).
#   - Native IPv6 wins: its default route is in main, looked up first.
#   - Cloudflare WARP wins while connected: its rule (5209) comes first;
#     when WARP is off or stuck its rule is gone and the fallback serves.
#   - The tunnel address is a ULA, so getaddrinfo (RFC 6724 label
#     mismatch) and browsers keep preferring IPv4 for dual-stack names;
#     the slow path over yggdrasil carries v6-only destinations.
#
# Pinning: the encapsulated packets are accepted only from the yggdrasil
# interface and the peer's address (raw prerouting, before conntrack);
# inside the tunnel only replies come in, at both ends: the client takes
# no new connections through it, the gateway's tenants open none, and the
# gateway's own services take new ones only at its public addresses
# (`publicSuffixes`, e.g. som's ::c0de:ba5e: teamclaude, the slots' SNI
# router), admitted there by the host firewall's interface-independent
# rules as it admits a connection from the internet (an upstream router's
# own filter not applied): the client sees what the internet sees of the
# gateway, nothing more (not its tunnel address, not its LAN, nothing
# opened only on br0/ygg/a veth). Refused destinations (the LAN, the
# gateway's other addresses) are rejected, not dropped: the client's
# connect fails at once instead of hanging in SYN-SENT (omp, herdr and
# browsers don't fall back to IPv4 on a timeout).
#
# Health (client): v6-fallback.timer ticks every 10 s. A tick (re)creates
# the tunnel if missing, pings the gateway's tunnel address through it,
# and adds the rules after a success or removes them after 3 failures in
# a row (gateway gone, yggdrasil down): applications then fail fast with
# "no route" instead of hanging. A withdrawal while on also holds the
# fallback off for `holdDown` seconds (mesh self-check: should it ever
# hurt the mesh, it backs off instead of flapping). Stopping
# v6-fallback.timer removes rules, route and link (v6-fallback-teardown;
# a switch that changes the tick restarts it: v6 pauses for one tick).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.v6Fallback;
  net = import ../../../home-networks { inherit lib; };
  clanDir = config.clan.core.settings.directory or null;
  yggOf =
    m:
    let
      f = clanDir + "/vars/per-machine/${m}/yggdrasil/address/value";
    in
    if clanDir != null && builtins.pathExists f then lib.trim (builtins.readFile f) else null;

  prefixOf = index: "fd99:6fb:0:${lib.toLower (lib.toHexString index)}";
  isClient = cfg.role == "client";
  isGateway = cfg.role == "gateway";

  iproute = "${pkgs.iproute2}/bin/ip";
  # Container traffic is selected by a mark set in prerouting, not by an
  # `iif` rule: the spaces' fail-fast check (nft `fib daddr . mark`,
  # ../spaces/host.nix, which cannot see iif rules) must find the same
  # route the packet will take. The top bit: clear of every fwmark user in
  # the fleet (tailscale 0xff0000, WARP 0x100cf, the Mullvad app
  # 0x6d6f6c65, som's slots 0x2000000, ../ipv4-forward.nix 0x10000000).
  mark = "0x80000000";

  # Outer packets (proto 41) to this machine's yggdrasil address only from
  # the yggdrasil interface and the expected peers, checked before
  # conntrack: the firewall's `ct state established` accept (the tunnel's
  # own outbound packets create that entry) and the loose reverse-path
  # check would otherwise let anyone on the local link inject packets
  # with the peer's outer address (and so, after decapsulation, anything).
  rawPin = peers: lib.optionalString (peers != [ ]) ''
    chain tunnel-pin {
      type filter hook prerouting priority raw; policy accept;
      ip6 daddr ${cfg.localYggAddress} meta l4proto ipv6 iifname != "ygg" counter drop
      ip6 daddr ${cfg.localYggAddress} meta l4proto ipv6 ip6 saddr != { ${lib.concatStringsSep ", " peers} } counter drop
    }
  '';

  # Leftovers of the hand-made hotfix: table ip6 v6fb-hotfix, rules
  # commented v6fb-hotfix (iptables-nft's ip6 filter FORWARD, nixos-fw),
  # its 2000::/3 route in main.
  cleanupHotfix = pkgs.writeShellScript "v6-fallback-cleanup-hotfix" ''
    PATH=${
      lib.makeBinPath [
        pkgs.nftables
        pkgs.gnugrep
        pkgs.gawk
        pkgs.iproute2
      ]
    }
    nft delete table ip6 v6fb-hotfix 2>/dev/null || true
    for chain in "ip6 filter FORWARD" "inet nixos-fw input-allow"; do
      # shellcheck disable=SC2086
      nft -a list chain $chain 2>/dev/null | grep 'comment "v6fb-hotfix"' |
        awk '{print $NF}' | while read -r h; do
          # shellcheck disable=SC2086
          nft delete rule $chain handle "$h" || true
        done
    done
    while ip -6 route del 2000::/3 table main dev v6fb 2>/dev/null; do :; done
    true
  '';

  clientTick = pkgs.writeShellApplication {
    name = "v6-fallback-tick";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.iputils
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.util-linux
      pkgs.systemd
    ];
    text = ''
      dev=v6fb
      local_ygg=${cfg.localYggAddress}
      remote_ygg=${cfg.gateway.yggAddress}
      addr=${prefixOf cfg.index}::2
      peer=${prefixOf cfg.index}::1
      table=${toString cfg.table}
      prio=${toString cfg.rulePriority}
      state=/run/v6-fallback
      mkdir -p "$state"
      # One at a time: a tick still in its ping must not re-add what a
      # stop just removed.
      exec 9>/run/v6-fallback.lock
      flock 9
      # A tick that waited on the lock while a stop ran: stay down.
      if [[ ''${1:-} != stop ]] && ! systemctl is-active -q v6-fallback-teardown.service; then
        exit 0
      fi

      rules_off() {
        while ip -6 rule del priority "$prio" 2>/dev/null; do :; done
      }
      rules_on() {
        local have
        have=$(ip -6 rule show priority "$prio")
        grep -qF "uidrange ${cfg.userRange} lookup $table" <<<"$have" ||
          ip -6 rule add priority "$prio" uidrange ${cfg.userRange} lookup "$table"
        grep -qF "fwmark ${mark}/${mark} lookup $table" <<<"$have" ||
          ip -6 rule add priority "$prio" fwmark ${mark}/${mark} lookup "$table"
      }

      if [[ ''${1:-} == stop ]]; then
        rules_off
        ip -6 route flush table "$table" 2>/dev/null || true
        ip link del "$dev" 2>/dev/null || true
        rm -rf "$state"
        exit 0
      fi

      # (Re)create the tunnel when missing or pointing elsewhere (e.g. the
      # hotfix's link of the same name).
      tun=$(ip -6 tunnel show "$dev" 2>/dev/null || true)
      if ! grep -q "remote $remote_ygg local $local_ygg" <<<"$tun"; then
        ip link del "$dev" 2>/dev/null || true
        ip link add "$dev" type ip6tnl mode ip6ip6 local "$local_ygg" remote "$remote_ygg" encaplimit none
      fi
      ip link set "$dev" mtu 1280 up
      ip -6 addr replace "$addr/64" dev "$dev" nodad
      # Re-asserted every tick (a networkd restart may drop foreign routes).
      ip -6 route replace 2000::/3 dev "$dev" table "$table"

      now=$(date +%s)
      hold=$(cat "$state/hold" 2>/dev/null || echo 0)
      fails=$(cat "$state/fails" 2>/dev/null || echo 0)
      if ping -6 -n -q -c1 -W${toString cfg.probeTimeout} -I "$dev" "$peer" >/dev/null 2>&1; then
        echo 0 >"$state/fails"
        if ((now < hold)); then
          exit 0
        fi
        [[ -e $state/up ]] || echo "v6-fallback: gateway answers through $dev, routing users' IPv6 through it"
        touch "$state/up"
        rules_on
      else
        fails=$((fails + 1))
        echo "$fails" >"$state/fails"
        if ((fails >= 3)); then
          if [[ -e $state/up ]]; then
            echo "v6-fallback: gateway silent $fails times, withdrawing the route for ${toString cfg.holdDown} s"
            rm -f "$state/up"
            echo $((now + ${toString cfg.holdDown})) >"$state/hold"
          fi
          rules_off
        fi
      fi
    '';
  };

  gwClients = lib.mapAttrsToList (
    name: c:
    c
    // {
      inherit name;
      dev = "v6fb-${name}";
    }
  ) cfg.clients;
in
{
  options.hyper.v6Fallback = {
    enable = lib.mkEnableOption "IPv6 for a v4-only client through a gateway over yggdrasil";
    role = lib.mkOption {
      type = lib.types.enum [
        "client"
        "gateway"
      ];
      description = "client: gets IPv6 through the gateway; gateway: carries the clients' IPv6.";
    };
    localYggAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = yggOf config.networking.hostName;
      defaultText = lib.literalExpression "this machine's yggdrasil/address var";
      description = "This machine's yggdrasil address (the tunnel's local end).";
    };

    # client
    index = lib.mkOption {
      type = lib.types.ints.between 1 255;
      default = 1;
      description = "Client: its tunnel /64 fd99:6fb:0:<index>::/64; equals the gateway's clients.<name>.index.";
    };
    gateway = {
      machine = lib.mkOption {
        type = lib.types.str;
        default = "som";
        description = "Client: the gateway machine.";
      };
      yggAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = yggOf cfg.gateway.machine;
        defaultText = lib.literalExpression "the gateway machine's yggdrasil/address var";
        description = "Client: the gateway's yggdrasil address.";
      };
    };
    userRange = lib.mkOption {
      type = lib.types.strMatching "[0-9]+-[0-9]+";
      default = "1000-29999";
      description = "Client: uids whose sockets may use the fallback (never root, nixbld or DynamicUsers such as yggdrasil).";
    };
    forwardInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.networking.nat.internalInterfaces;
      defaultText = lib.literalExpression "config.networking.nat.internalInterfaces";
      description = "Client: interfaces whose forwarded traffic (containers, masqueraded by nixos-nat) may use the fallback.";
    };
    table = lib.mkOption {
      type = lib.types.int;
      default = 6464;
      description = "Client: routing table holding the 2000::/3 route into the tunnel.";
    };
    rulePriority = lib.mkOption {
      type = lib.types.int;
      default = 32800;
      description = "Client: after main (32766), so native IPv6 and WARP (5209) win.";
    };
    holdDown = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Client: seconds the fallback stays off after it was withdrawn for a silent gateway.";
    };
    probeTimeout = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Client: seconds to wait for the gateway's answer per tick (yggdrasil over a poor Wi-Fi: 1-2 s RTT).";
    };

    # gateway
    clients = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              index = lib.mkOption {
                type = lib.types.ints.between 1 255;
                description = "The client's tunnel /64 fd99:6fb:0:<index>::/64.";
              };
              yggAddress = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = yggOf name;
                defaultText = lib.literalExpression "the client machine's yggdrasil/address var";
                description = "The client's yggdrasil address.";
              };
            };
          }
        )
      );
      default = { };
      description = "Gateway: the clients it carries, by machine name (interface v6fb-<name>, name at most 10 chars).";
    };
    uplinkInterface = lib.mkOption {
      type = lib.types.str;
      default = "br0";
      description = "Gateway: the interface with native IPv6 the clients' traffic leaves through (masqueraded).";
    };
    blockedDestinations = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = net.publicLanPrefixes;
      defaultText = lib.literalExpression "home-networks' publicLanPrefixes";
      description = "Gateway: global prefixes the clients may not reach through it (the gateway's own LAN).";
    };
    publicSuffixes = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "::([0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4}");
      default = [ ];
      example = [ "::c0de:ba5e" ];
      description = "Gateway: interface ids (lower 64 bits, any global prefix: the RA's prefix may change) of this host's public addresses. The clients may open connections to them through the tunnel, which the host firewall then admits as from the internet; its other addresses stay closed to them.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = config.services.yggdrasil.enable;
            message = "hyper.v6Fallback rides yggdrasil";
          }
          {
            assertion = cfg.localYggAddress != null;
            message = "hyper.v6Fallback: no yggdrasil address for this machine";
          }
          {
            assertion = config.networking.nftables.enable;
            message = "hyper.v6Fallback needs the nftables firewall";
          }
        ];
        boot.kernelModules = [ "ip6_tunnel" ];
      }

      (lib.mkIf isClient {
        assertions = [
          {
            assertion = cfg.gateway.yggAddress != null;
            message = "hyper.v6Fallback: no yggdrasil address for gateway ${cfg.gateway.machine}";
          }
        ];
        # The encapsulated packets from the gateway, and nothing else.
        networking.firewall.extraInputRules = ''
          iifname "ygg" ip6 saddr ${cfg.gateway.yggAddress} meta l4proto ipv6 accept
        '';
        # Replies from the internet have no route back in main (by design),
        # so the reverse-path fib check would drop them. The tunnel's outer
        # packets are pinned to the gateway's key-bound address above.
        networking.firewall.extraReversePathFilterRules = ''
          iifname "v6fb" accept
        '';
        networking.nftables.tables.v6-fallback = {
          family = "ip6";
          content = ''
            ${rawPin [ cfg.gateway.yggAddress ]}
            chain input {
              type filter hook input priority filter - 5; policy accept;
              iifname "v6fb" ct state established,related accept
              iifname "v6fb" counter drop
            }
            chain forward-in {
              type filter hook forward priority filter - 5; policy accept;
              iifname "v6fb" ct state established,related accept
              iifname "v6fb" counter drop
            }
            chain prerouting {
              type filter hook prerouting priority mangle - 5; policy accept;
              ${lib.optionalString (cfg.forwardInterfaces != [ ]) ''
                iifname { ${
                  lib.concatMapStringsSep ", " (i: ''"${i}"'') cfg.forwardInterfaces
                } } ip6 daddr 2000::/3 meta mark set meta mark | ${mark}
              ''}
            }
            chain forward {
              type filter hook forward priority mangle; policy accept;
              oifname "v6fb" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
            }
            chain output {
              type route hook output priority mangle; policy accept;
              oifname "v6fb" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
            }
          '';
        };
        networking.networkmanager.unmanaged = [ "interface-name:v6fb" ];
        # networkd deletes routing policy rules it did not create whenever
        # it (re)configures any link it manages (a container veth coming
        # up, wg-*): that took the fallback's rules away for up to a tick,
        # and does the same to WARP's (5209) and tailscale's. Rules here
        # belong to the daemons that add them.
        systemd.network.config.networkConfig.ManageForeignRoutingPolicyRules = false;

        systemd.services.v6-fallback = {
          description = "IPv6 fallback through ${cfg.gateway.machine} over yggdrasil (one tick)";
          after = [
            "yggdrasil.service"
            "network.target"
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe clientTick}";
          };
        };
        systemd.timers.v6-fallback = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnActiveSec = "5s";
            OnUnitActiveSec = "10s";
            AccuracySec = "1s";
          };
        };
        # Cleanup once per boot/switch (hotfix leftovers), and removal of
        # rules, route and link when the timer stops (the tick has no stop).
        systemd.services.v6-fallback-teardown = {
          description = "Remove the IPv6 fallback's rules, route and tunnel when stopped";
          wantedBy = [ "v6-fallback.timer" ];
          before = [ "v6-fallback.timer" ];
          partOf = [ "v6-fallback.timer" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${cleanupHotfix}";
            ExecStop = "${lib.getExe clientTick} stop";
          };
        };
      })

      (lib.mkIf isGateway {
        assertions = lib.mapAttrsToList (n: c: {
          assertion = c.yggAddress != null && lib.stringLength "v6fb-${n}" <= 15;
          message = "hyper.v6Fallback.clients.${n}: needs a yggdrasil address and a name of at most 10 chars";
        }) cfg.clients;
        boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkDefault 1;

        networking.firewall.extraInputRules = lib.concatMapStrings (c: ''
          iifname "ygg" ip6 saddr ${c.yggAddress} meta l4proto ipv6 accept
        '') gwClients;

        networking.nftables.tables.v6-fallback = {
          family = "ip6";
          content = ''
            ${rawPin (map (c: c.yggAddress) gwClients)}
            # amy itself: answers to its probe and replies; new connections
            # only to this host's public addresses, then decided by the
            # host firewall (nixos-fw's input base chain, a later one; new
            # packets there go through input-allow) as for the internet: an
            # accept here only passes them on.
            chain input {
              type filter hook input priority filter - 5; policy accept;
              ${lib.concatMapStrings (c: ''
                iifname "${c.dev}" ip6 saddr != { ${prefixOf c.index}::2, fe80::/10 } counter drop
              '') gwClients}
              iifname "v6fb-*" ct state established,related accept
              iifname "v6fb-*" icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, packet-too-big } accept
              ${lib.concatMapStrings (sfx: ''
                iifname "v6fb-*" ip6 daddr 2000::/3 ip6 daddr & ::ffff:ffff:ffff:ffff == ${sfx} accept
              '') cfg.publicSuffixes}
              iifname "v6fb-*" counter reject with icmpv6 admin-prohibited
            }
            # This host's own users (other tenants) never open anything
            # towards the client through the tunnel.
            chain output {
              type filter hook output priority filter - 5; policy accept;
              oifname "v6fb-*" ct state established,related accept
              # destination-unreachable: the rejects of input and forward
              # (their packet never made a conntrack entry to be related to)
              oifname "v6fb-*" icmpv6 type { destination-unreachable, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, packet-too-big } accept
              oifname "v6fb-*" counter drop
            }
            chain forward {
              type filter hook forward priority filter - 5; policy accept;
              oifname "v6fb-*" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
              iifname "v6fb-*" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
              ${lib.concatMapStrings (c: ''
                iifname "${c.dev}" ip6 saddr != ${prefixOf c.index}::2 counter drop
              '') gwClients}
              iifname "v6fb-*" oifname != "${cfg.uplinkInterface}" counter drop
              iifname "v6fb-*" ip6 daddr != 2000::/3 counter drop
              ${lib.optionalString (cfg.blockedDestinations != [ ]) ''
                iifname "v6fb-*" ip6 daddr { ${lib.concatStringsSep ", " cfg.blockedDestinations} } counter reject with icmpv6 admin-prohibited
              ''}
              iifname "v6fb-*" accept
              oifname "v6fb-*" ct state established,related accept
              oifname "v6fb-*" counter drop
            }
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              iifname "v6fb-*" oifname "${cfg.uplinkInterface}" masquerade
            }
          '';
        };
        networking.networkmanager.unmanaged = [ "interface-name:v6fb-*" ];

        systemd.services = lib.listToAttrs (
          map (
            c:
            lib.nameValuePair "v6-fallback-${c.name}" {
              description = "IPv6 fallback tunnel for ${c.name} over yggdrasil";
              after = [
                "yggdrasil.service"
                "network.target"
              ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStartPre = [ "${cleanupHotfix}" ];
                ExecStop = "-${iproute} link del ${c.dev}";
              };
              script = ''
                ${iproute} link del v6fb 2>/dev/null || true
                ${iproute} link del ${c.dev} 2>/dev/null || true
                ${iproute} link add ${c.dev} type ip6tnl mode ip6ip6 \
                  local ${cfg.localYggAddress} remote ${c.yggAddress} encaplimit none
                ${iproute} link set ${c.dev} mtu 1280 up
                ${iproute} -6 addr replace ${prefixOf c.index}::1/64 dev ${c.dev} nodad
              '';
            }
          ) gwClients
        );
      })
    ]
  );
}
