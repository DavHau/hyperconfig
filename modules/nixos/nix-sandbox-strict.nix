# som's nix-daemon builds for users it does not trust: every container on
# som (all are services.container-slots: the hyperhermes agents' slots and
# the others like asof; each talks to this host daemon socket,
# hyperhermes/modules/container-slots.nix), every hyperhermes agent and
# `nixremote`, the remote-building builder account
# (../clan/remote-building). ./nix-gc.nix sets sandbox = "relaxed", which
# lets any of them run a `__noChroot` derivation unsandboxed on the host as
# a build user: full filesystem view and host network. Strict sandboxing
# refuses those derivations outright. impure-derivations and recursive-nix
# (./nix-gc.nix) stay enabled; their builds still run sandboxed.
#
# What the sandbox does not isolate is the network of fixed-output and
# impure derivations: nix gives only the other derivations a private
# network namespace (CLONE_NEWNET in linux-derivation-builder.cc, gated on
# isSandboxed()), so a fetcher's sockets live in the host's namespace and
# reach whatever som reaches: its own services on loopback and its
# addresses, the LAN, the overlays (yggdrasil, tinc, zerotier, hyprspace,
# wg-vault). The output chain below leaves those builders the internet
# only, mirroring the isolated slots' forward policy
# (hyperhermes/modules/container-slots.nix, isolated-out). Substitution is
# done by the daemon itself as root and is not affected.
#
# Matching the builders: som runs auto-allocate-uids (./common.nix), so a
# build owns a block of 65536 ids from start-id (default 0x34000000, 128
# blocks, nix's AutoAllocateUidSettings) and, being in a user namespace,
# uses its first uid as gid too. The socket owner nftables sees is that
# host id, also for builds that are root inside their namespace
# (uid-range). The nixbld group catches the classic nixbldN build users
# should auto-allocate-uids ever be turned off.
{ config, lib, ... }:
let
  startId = config.nix.settings.start-id or 872415232;
  idCount = config.nix.settings.id-count or (65536 * 128);
  slots = config.services.container-slots;
  blocked4 = lib.filter (d: !lib.hasInfix ":" d) slots.isolatedBlockedDestinations;
  blocked6 = lib.filter (lib.hasInfix ":") slots.isolatedBlockedDestinations;
  set = ds: "{ ${lib.concatStringsSep ", " ds} }";
in
{
  nix.settings.sandbox = lib.mkForce true;

  networking.nftables.enable = true;
  networking.nftables.tables.nix-build-egress = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${toString startId}-${toString (startId + idCount - 1)} jump builder
        meta skgid ${toString config.users.groups.nixbld.gid} jump builder
      }

      chain builder {
        # Name resolution: a fixed-output build gets the host's
        # /etc/resolv.conf, which points at the systemd-resolved stub.
        ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53 accept
        # som's own addresses (its public IPv4 and v6 included).
        fib daddr type local reject with icmpx admin-prohibited
        ip daddr ${
          set (
            [
              "0.0.0.0/8"
              "127.0.0.0/8"
              "10.0.0.0/8"
              "172.16.0.0/12"
              "192.168.0.0/16"
              "100.64.0.0/10"
              "169.254.0.0/16"
              "224.0.0.0/4"
              "255.255.255.255"
              slots.lanIPv4
            ]
            ++ blocked4
          )
        } reject with icmpx admin-prohibited
        # 200::/7 yggdrasil, 42::/16 tinc retiolum, fc00::/7 the ULA
        # overlays (zerotier, hyprspace, wg-vault, Mullvad's own).
        ip6 daddr ${
          set (
            [
              "::/128"
              "::1/128"
              "fc00::/7"
              "fe80::/10"
              "ff00::/8"
              "200::/7"
              "42::/16"
              "${slots.ipv6Prefix}::/64"
            ]
            ++ blocked6
          )
        } reject with icmpx admin-prohibited
      }
    '';
  };
}
