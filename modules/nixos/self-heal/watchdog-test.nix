# VM test of ./watchdog.nix (check self-heal-net-watchdog). A router
# (gateway of vlan 1, forwards to vlan 2) and `upstream` on vlan 2, which
# stands in for the internet (192.168.2.200, the internet probe) and for the
# overlay anchors (its primary address). nftables on the router cuts
# upstream off (or kills the router); nftables on a node cuts only its own
# path to the anchor (the mesh state) or everything (its link).
# `mesh-standin` plays the mesh daemons; /run/break-mesh and
# /run/break-sshd make the stand-in or sshd unrestartable. Ticks are started
# by hand (the timer is off) and a fake clock (testClockFile, seconds added
# to the watchdog's uptime and wall clock) moves time forward, so 30 min or
# 7 h cost nothing and the script never sleeps. Thresholds: the defaults,
# but rebootAfter 10 min and meshRebootAfter 15 min (no jitter).
# Nodes: wd (subtests a h b f g c), peera + peerb (j: no default route; d i: mutual tang peers;
# their "reboot" is testRebootCommand, so both can be ticked at once),
# laptop (e, roaming = report only).
{
  pkgs,
  subtests ? [
    "a"
    "h"
    "j"
    "b"
    "f"
    "g"
    "c"
    "d"
    "i"
    "e"
  ],
}:
let
  inherit (pkgs) lib;
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  clockFile = "/var/lib/selfheal-test-clock";

  common =
    {
      nodes,
      lib,
      ...
    }:
    {
      imports = [ ./default.nix ];
      virtualisation.vlans = [ 1 ];
      networking.defaultGateway = nodes.router.networking.primaryIPAddress;
      # QEMU's user-net on eth0 would be a second default route (DHCP v4,
      # RA v6) whose gateway always answers: only the router may be one.
      networking.dhcpcd.enable = lib.mkForce false;
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.default.accept_ra" = 0;
        "net.ipv6.conf.eth0.accept_ra" = 0;
      };
      networking.nftables.enable = true;
      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      # Unrestartable while /run/break-sshd exists.
      systemd.services.sshd.serviceConfig.ExecStartPre = lib.mkBefore [
        "${pkgs.bash}/bin/sh -c '! test -e /run/break-sshd'"
      ];
      # Unrestartable while /run/break-mesh exists.
      systemd.services.mesh-standin = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStartPre = "${pkgs.bash}/bin/sh -c '! test -e /run/break-mesh'";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };
      hyper.selfHeal = {
        enable = true;
        anchors = [ nodes.upstream.networking.primaryIPAddress ];
        anchorsPublic = [ ];
        internetProbes = [ "192.168.2.200" ];
        meshUnits = [ "mesh-standin.service" ];
        watchdog = {
          rebootAfter = 600;
          meshRebootAfter = 900;
          meshRebootJitter = 0;
          # the fake clock makes every unit look old: only (f) ages a switch
          switchHungAfter = 100000;
          testClockFile = clockFile;
        };
      };
      # ticks are started by the test script
      systemd.timers.selfheal-net-watchdog.enable = false;
    };

  # Fixed link-locals, so the peers can name each other at build time.
  linkLocal = {
    peera = "fe80::a";
    peerb = "fe80::b";
  };

  peer =
    other:
    {
      nodes,
      config,
      ...
    }:
    {
      imports = [ common ];
      virtualisation.memorySize = 768;
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = linkLocal.${config.networking.hostName};
          prefixLength = 64;
        }
      ];
      # the ECDSA snake oil key: root's unrestricted key (common) is the
      # ed25519 one, and sshd uses the first line that matches
      environment.etc."selfheal-peer-key" = {
        source = keys.snakeOilPrivateKey;
        mode = "0600";
      };
      hyper.selfHeal.watchdog = {
        tangPeer = other;
        # the tang link-local path, like vit <-> som (review L3: from= must
        # be a wildcard, a CIDR never matches a scoped link-local client)
        peerAddresses = [ "${linkLocal.${other}}%eth1" ];
        peerFrom = [ "fe80::*" ];
        peerKeyFile = "/etc/selfheal-peer-key";
        peerPublicKey = keys.snakeOilPublicKey;
        peerHostKey = null;
        seatWarning = false;
        # "rebooting": unreachable from now on (the test stops ticking it)
        testRebootCommand = "${pkgs.writeShellScript "fake-reboot" ''
          touch /run/fake-rebooted
          ${pkgs.systemd}/bin/systemctl stop --no-block sshd.service
        ''}";
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "self-heal-net-watchdog";

  nodes.router =
    { nodes, ... }:
    {
      virtualisation.vlans = [
        1
        2
      ];
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      networking.firewall.enable = false;
      networking.nftables.enable = true;
      environment.etc."ssh-key" = {
        source = keys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
    };

  nodes.upstream =
    { nodes, ... }:
    {
      virtualisation.vlans = [ 2 ];
      networking.defaultGateway = lib.head (map (a: a.address) nodes.router.networking.interfaces.eth2.ipv4.addresses);
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "192.168.2.200";
          prefixLength = 24;
        }
      ];
      services.openssh.enable = true;
    };

  nodes.wd = {
    imports = [ common ];
    virtualisation.memorySize = 1024;
    users.users.alice = {
      isNormalUser = true;
      password = "foobar";
    };
    # Full mode with the seat warning (tty sessions count: the warning goes
    # out by wall; notify-send only for wayland/x11 sessions).
    hyper.selfHeal.watchdog = {
      mode = "full";
      seatWarning = true;
    };
  };

  # A host whose uplink is a bridge that also carries a local container's
  # veth (som's br0 + nspawn): the container answers ff02::1, but only a
  # neighbour behind the physical port eth1 may count (review L2).
  nodes.brh =
    { nodes, lib, ... }:
    {
      imports = [ common ];
      virtualisation.memorySize = 768;
      networking.bridges.br0.interfaces = [ "eth1" ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
      networking.interfaces.br0.ipv4.addresses = [
        {
          address = nodes.brh.networking.primaryIPAddress;
          prefixLength = 24;
        }
      ];
      systemd.services.fake-container = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network-addresses-br0.service" "br0-netdev.service" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ip netns add ctr
          ip link add vb-ctr type veth peer name host0 netns ctr
          ip link set vb-ctr master br0 up
          ip -n ctr link set lo up
          ip -n ctr link set host0 up
        '';
      };
    };

  nodes.peera = peer "peerb";
  nodes.peerb = peer "peera";

  nodes.laptop = {
    imports = [ common ];
    hyper.selfHeal.roaming = true;
  };

  testScript =
    { nodes, ... }:
    ''
      import datetime
      import json
      import threading

      SUBTESTS = ${builtins.toJSON subtests}
      UP = "${nodes.upstream.networking.primaryIPAddress}"
      RGW = "${nodes.router.networking.primaryIPAddress}"
      WD = "${nodes.wd.networking.primaryIPAddress}"
      PEERB = "${nodes.peerb.networking.primaryIPAddress}"
      SSH = "${pkgs.openssh}/bin/ssh -n -i /etc/ssh-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

      def secs(n):
          return datetime.timedelta(seconds=n)

      def clock(m, s):
          m.succeed(f"echo {s} > ${clockFile}")

      def tick(m):
          m.succeed("systemctl start selfheal-net-watchdog.service")

      def at(m, s):
          clock(m, s)
          tick(m)
          return st(m)

      def st(m):
          return json.loads(m.succeed("selfheal watchdog status --json"))["state"]

      def actions(m):
          return st(m).get("actions", {})

      def boot_id(m):
          return m.succeed("cat /proc/sys/kernel/random/boot_id").strip()

      def metric(m, line):
          m.succeed(f"grep -qxF '{line}' /run/selfheal/watchdog.prom")

      def events(m, kind):
          rc, o = m.execute("cat /var/lib/selfheal/log.jsonl")
          return [e for e in (json.loads(x) for x in o.splitlines()) if e["event"] == kind] if rc == 0 else []

      def reboot_tick(m):
          b0 = boot_id(m)
          m.execute("systemctl start --no-block selfheal-net-watchdog.service")
          m.wait_for_shutdown(timeout=secs(120))
          m.start()
          m.wait_for_unit("multi-user.target")
          assert boot_id(m) != b0

      def break_mesh(m):
          """The mesh stand-in down for good: restore can't fix it."""
          m.succeed("touch /run/break-mesh && systemctl stop mesh-standin.service")

      def break_sshd(m):
          m.succeed("touch /run/break-sshd && systemctl stop sshd.service")

      def heal(m):
          m.succeed("rm -f /run/break-mesh /run/break-sshd",
                    "systemctl reset-failed mesh-standin.service sshd.service",
                    "systemctl start mesh-standin.service sshd.service",
                    "nft delete table inet cut || true",
                    "ip link set eth1 up",
                    # a link that went down took its routes with it
                    f"ip route replace default via {RGW}")

      def cut_anchor(m):
          """Only the overlay anchor is unreachable from m: the mesh state."""
          m.succeed("nft add table inet cut",
                    "nft add chain inet cut ocut '{ type filter hook output priority 0; }'",
                    f"nft add rule inet cut ocut ip daddr {UP} drop")

      def cut_link(m):
          """m's own link is dead (no carrier on its uplink). An nft output
          drop is not enough: arping's packet socket bypasses it."""
          m.succeed("ip link set eth1 down")

      def reset(m):
          m.succeed("rm -rf /var/lib/selfheal/watchdog /run/fake-rebooted /run/selfheal/watchdog-peer.json")

      start_all()
      router.wait_for_unit("multi-user.target")
      upstream.wait_for_unit("sshd.service")
      for m in [wd, peera, peerb, laptop, brh]:
          m.wait_for_unit("multi-user.target")
          m.wait_for_unit("mesh-standin.service")
          clock(m, 0)
      brh.wait_for_unit("fake-container.service")

      for m in [wd, peera, peerb, laptop, brh]:
          routes = m.succeed("ip route show default; ip -6 route show default")
          assert "eth0" not in routes, (m.name, routes)

      with subtest("baseline: all ok"):
          for m in [wd, peera, peerb, laptop, brh]:
              m.wait_until_succeeds("selfheal health", timeout=60)
              tick(m)
              assert st(m)["state"] == "ok", st(m)
          metric(wd, 'selfheal_watchdog_state{state="ok"} 1')
          metric(laptop, 'selfheal_watchdog_mode{mode="report"} 1')

      if "a" in SUBTESTS:
          with subtest("(a) upstream outage: 2 h, no action, no reboot"):
              b0 = boot_id(wd)
              router.succeed(
                  "nft add table inet cut",
                  "nft add chain inet cut forward_cut '{ type filter hook forward priority 0; }'",
                  f"nft add rule inet cut forward_cut ip daddr '{{ {UP}, 192.168.2.200 }}' drop",
              )
              for i in range(25):
                  s = at(wd, 4000 + i * 300)
                  assert s["state"] == "upstream", s
              assert actions(wd) == {}, actions(wd)
              assert "incidentStart" not in st(wd)
              metric(wd, 'selfheal_watchdog_state{state="upstream"} 1')
              metric(wd, 'selfheal_watchdog_actions_total{action="reboot"} 0')
              metric(wd, 'selfheal_watchdog_unreachable_seconds 0')
              assert boot_id(wd) == b0
              router.succeed("nft delete table inet cut")
              assert at(wd, 11500)["state"] == "ok", st(wd)

      if "h" in SUBTESTS:
          with subtest("(h) dead router but LAN neighbours answer: upstream; our own link dead: link"):
              router.succeed(
                  "nft add table inet dead",
                  "nft add chain inet dead in_dead '{ type filter hook input priority 0; }'",
                  "nft add rule inet dead in_dead iifname eth1 drop",
                  "nft add chain inet dead fwd_dead '{ type filter hook forward priority 0; }'",
                  "nft add rule inet dead fwd_dead drop",
              )
              for i in range(4):
                  s = at(wd, 4000 + i * 600)
                  assert s["state"] == "upstream", s
              assert actions(wd) == {} and "incidentStart" not in st(wd), st(wd)
              # bridged uplink: the LAN neighbours come in through eth1
              s = at(brh, 4000)
              assert s["state"] == "upstream", s
              router.succeed("nft delete table inet dead")
              assert at(brh, 4060)["state"] == "ok", st(brh)
              # brh's NIC wedged (carrier up, nothing gets in): the local
              # container still answers ff02::1 on br0, but behind a veth
              brh.succeed("ip netns exec ctr ping -6 -c1 -W2 ff02::1%host0 | grep -q 'bytes from'")
              # Carrier up, nothing comes in through eth1 (a bridge-family
              # drop before the bridge decides): the gateway, the LAN, all
              # silent; only the local container answers, behind its veth.
              brh.succeed(
                  "nft add table bridge wedge",
                  "nft add chain bridge wedge pre_wedge '{ type filter hook prerouting priority -300; }'",
                  "nft add rule bridge wedge pre_wedge iifname eth1 drop",
                  "nft add chain bridge wedge out_wedge '{ type filter hook output priority -300; }'",
                  "nft add rule bridge wedge out_wedge oifname eth1 drop",
                  "ip neigh flush dev br0",
              )
              clock(brh, 5000)
              tick(brh)
              s = st(brh)
              if s["state"] != "link":
                  print(brh.execute("selfheal health --level local; ip route; ip -6 route; bridge link; bridge fdb show br br0; ip neigh; nft list ruleset; ping -6 -c2 -w3 ff02::1%br0")[1])
              assert s["state"] == "link", s
              brh.succeed("nft delete table bridge wedge")
              assert at(brh, 5060)["state"] == "ok", st(brh)
              # carrier lost on the only physical port: link, whatever the bridge hears
              brh.succeed("ip link set eth1 down")
              s = at(brh, 5200)
              if s["state"] != "link":
                  print(brh.execute("selfheal health --level local; cat /sys/class/net/eth1/carrier; bridge link")[1])
              assert s["state"] == "link", s
              brh.succeed("ip link set eth1 up")
              brh.wait_until_succeeds("selfheal health --level local", timeout=60)
              assert at(brh, 5300)["state"] == "ok", st(brh)
              assert at(wd, 7000)["state"] == "ok", st(wd)
              # vit's wedged Wi-Fi: nobody answers, not even a neighbour
              cut_link(wd)
              s = at(wd, 8000)
              assert s["state"] == "link", s
              at(wd, 8060)
              assert actions(wd).get("uplink_restart") is None, actions(wd)
              at(wd, 8400)
              assert actions(wd).get("uplink_restart") == 1, actions(wd)
              heal(wd)
              wd.wait_until_succeeds("selfheal health", timeout=60)
              assert at(wd, 8460)["state"] == "ok", st(wd)

      if "j" in SUBTESTS:
          with subtest("(j) no default route: LAN answers -> noroute (uplink repairs, never a reboot); LAN silent -> link"):
              # a router dead past the DHCP lease (review R1): the route is
              # gone, the tang peer still answers on the remembered uplink
              assert at(peera, 3900)["gwDevs"] == ["eth1"], st(peera)
              peera.succeed("ip route del default")
              for i in range(12):
                  s = at(peera, 4000 + i * 300)
                  assert s["state"] == "noroute", s
                  assert "incidentStart" not in s and "intentSince" not in s, s
              assert actions(peera).get("uplink_restart", 0) >= 1, actions(peera)
              assert actions(peera).get("reboot") is None, actions(peera)
              peera.fail("test -e /run/fake-rebooted")
              # nobody on the LAN answers either (output drop: no carrier
              # loss, which would flush the link-local): our link, counted
              peera.succeed("nft add table inet cut",
                            "nft add chain inet cut ocut '{ type filter hook output priority 0; }'",
                            "nft add rule inet cut ocut oifname eth1 drop")
              s = at(peera, 8000)
              assert s["state"] == "link" and "incidentStart" in s, s
              peera.succeed("nft delete table inet cut", f"ip route add default via {RGW}")
              assert at(peera, 8060)["state"] == "ok", st(peera)
              peera.succeed("rm -rf /var/lib/selfheal/watchdog")

      if "b" in SUBTESTS:
          with subtest("(b) local fault: staged repair; a dead mesh daemon while reachable never reboots; sshd dead reboots once"):
              b0 = boot_id(wd)
              wd.succeed("systemctl stop sshd.service mesh-standin.service")
              assert at(wd, 4000)["state"] == "services", st(wd)
              # debounce: no restore on the first bad tick
              assert actions(wd).get("restore") is None, actions(wd)
              at(wd, 4060)
              assert actions(wd).get("restore") == 1, actions(wd)
              wd.wait_until_succeeds("systemctl is-active sshd.service mesh-standin.service", timeout=30)
              s = at(wd, 4120)
              assert s["state"] == "ok" and "incidentStart" not in s, s
              assert boot_id(wd) == b0

              # B1: the mesh stand-in stays dead, the anchor answers: degraded
              break_mesh(wd)
              for i in range(14):
                  s = at(wd, 5000 + i * 600)
                  assert s["state"] == "degraded", s
                  assert "incidentStart" not in s and "intentSince" not in s and not s.get("lastBlock"), s
              assert actions(wd).get("restore", 0) >= 3 and actions(wd).get("reboot") is None, actions(wd)
              metric(wd, 'selfheal_watchdog_state{state="degraded"} 1')
              assert boot_id(wd) == b0
              heal(wd)
              assert at(wd, 14000)["state"] == "ok", st(wd)

              # sshd unrestartable; a remote ssh session must not hold it up
              router.succeed(f"systemd-run --unit=sshhold {SSH} root@{WD} sleep 900")
              wd.wait_until_succeeds("loginctl list-sessions --no-legend | grep -q root", timeout=30)
              break_sshd(wd)
              at(wd, 15000)
              s = at(wd, 15300)
              assert s["state"] == "services" and boot_id(wd) == b0, s
              assert actions(wd).get("reboot") is None
              clock(wd, 15700)
              reboot_tick(wd)
              lr = json.loads(wd.succeed("cat /var/lib/selfheal/watchdog/last-reboot.json"))
              assert lr["kind"] == "reboot" and lr["state"] == "services", lr

              # right after boot: the 30 min grace blocks, then the daily cap
              b1 = boot_id(wd)
              break_sshd(wd)
              at(wd, 0)
              s = at(wd, 700)
              assert s.get("lastBlock") == "boot-grace", s
              s = at(wd, 2500)
              assert s.get("lastBlock") == "daily-cap", s
              metric(wd, 'selfheal_watchdog_reboot_blocked{gate="daily-cap"} 1')
              wd.succeed("grep -q '^selfheal_watchdog_last_reboot_timestamp_seconds{kind=\"reboot\"} ' /run/selfheal/watchdog.prom")
              assert boot_id(wd) == b1
              heal(wd)
              assert at(wd, 2560)["state"] == "ok", st(wd)

      if "f" in SUBTESTS:
          with subtest("(f) no repairs and no reboot while a switch runs or a hold is on"):
              wd.succeed("rm -f /var/lib/selfheal/watchdog/last-reboot.json")
              r0 = actions(wd).get("restore", 0)
              b0 = boot_id(wd)
              wd.succeed("systemd-run --unit=clan-switch-wd-00000001 sleep 600")
              wd.succeed("systemctl stop sshd.service")
              for t in (4000, 4060, 4700):
                  s = at(wd, t)
              assert s["state"] == "services" and s.get("repairsHeld"), s
              assert actions(wd).get("restore", 0) == r0, actions(wd)
              assert s.get("lastBlock") == "switch", s
              wd.fail("systemctl is-active sshd.service")
              assert len(events(wd, "watchdog-repairs-held")) >= 1
              wd.succeed("systemctl stop clan-switch-wd-00000001.service")
              s = at(wd, 4760)
              assert actions(wd).get("restore", 0) == r0 + 1, actions(wd)
              assert s.get("lastBlock") == "just-repaired", s
              wd.wait_until_succeeds("systemctl is-active sshd.service", timeout=30)
              assert at(wd, 4820)["state"] == "ok", st(wd)

              # a switch running longer than switchHungAfter is hung: ignored
              r1 = actions(wd).get("restore", 0)
              wd.succeed("systemd-run --unit=clan-switch-wd-00000002 sleep 600")
              wd.succeed("systemctl stop sshd.service")
              at(wd, 200000)
              s = at(wd, 200060)
              assert not s.get("repairsHeld") and actions(wd).get("restore", 0) == r1 + 1, s
              assert len(events(wd, "switch-hung")) == 1, events(wd, "switch-hung")
              wd.wait_until_succeeds("systemctl is-active sshd.service", timeout=30)
              assert at(wd, 200120)["state"] == "ok", st(wd)
              assert len(events(wd, "switch-hung")) == 1, events(wd, "switch-hung")
              wd.succeed("systemctl stop clan-switch-wd-00000002.service")
              r0 = actions(wd).get("restore", 0) - 1

              wd.succeed("selfheal hold 60")
              wd.succeed("systemctl stop sshd.service")
              for t in (5000, 5060, 5700):
                  s = at(wd, t)
              assert s.get("repairsHeld") and s.get("lastBlock") == "hold", s
              assert actions(wd).get("restore", 0) == r0 + 1, actions(wd)
              wd.fail("systemctl is-active sshd.service")
              wd.succeed("selfheal release")
              at(wd, 5760)
              assert actions(wd).get("restore", 0) == r0 + 2, actions(wd)
              wd.wait_until_succeeds("systemctl is-active sshd.service", timeout=30)
              assert at(wd, 5820)["state"] == "ok", st(wd)
              assert boot_id(wd) == b0

      if "g" in SUBTESTS:
          with subtest("(g) mesh state: mesh restarts, counted only after meshRebootAfter and two restarts"):
              b0 = boot_id(wd)
              cut_anchor(wd)
              s = at(wd, 4000)
              assert s["state"] == "mesh", s
              at(wd, 4060)
              assert actions(wd).get("mesh_restart") == 1, actions(wd)
              s = at(wd, 4700)
              # past rebootAfter (600 s), not yet past meshRebootAfter (900 s)
              assert actions(wd).get("mesh_restart") == 2, actions(wd)
              assert "intentSince" not in s and not s.get("lastBlock"), s
              # counted now; the hold shows it (and keeps the machine up)
              wd.succeed("selfheal hold 60")
              s = at(wd, 5000)
              assert s.get("lastBlock") == "hold", s
              wd.succeed("selfheal release")
              heal(wd)
              assert at(wd, 5060)["state"] == "ok", st(wd)
              assert boot_id(wd) == b0

      if "c" in SUBTESTS:
          with subtest("(c) seat warning: cancel once from the seat, the re-armed warning can't be"):
              wd.succeed("rm -f /var/lib/selfheal/watchdog/last-reboot.json")
              b0 = boot_id(wd)
              wd.succeed("systemctl start getty@tty2.service")
              wd.send_key("alt-f2")
              wd.wait_until_tty_matches("2", "login: ", timeout=60)
              wd.send_chars("alice\n")
              wd.wait_until_tty_matches("2", "Password: ", timeout=60)
              wd.send_chars("foobar\n")
              wd.wait_until_succeeds("loginctl show-user alice -p State | grep -q active", timeout=30)
              cut_anchor(wd)
              for t in (4000, 4060, 4700):
                  at(wd, t)
              s = at(wd, 5000)
              assert s.get("lastBlock") == "seat-countdown" and s["warning"]["cancellable"], s
              wd.wait_until_tty_matches("2", "will reboot in 5:00", timeout=60)
              # remote use neither blocks nor cancels
              out = router.succeed(f"{SSH} root@{WD} selfheal cancel 2>&1 || true")
              assert "refused" in out, out
              # nor does a command the seat user starts remotely in their manager
              out = router.succeed(f"{SSH} root@{WD} systemd-run --user --machine=alice@ --wait --pipe /run/current-system/sw/bin/selfheal cancel 2>&1 || true")
              assert "refused" in out and "cancelled;" not in out, out
              assert st(wd).get("warning"), st(wd)
              wd.send_chars("clear; selfheal cancel; echo rc=$?\n")
              wd.wait_until_tty_matches("2", "rc=0", timeout=60)
              s = st(wd)
              assert s.get("warning") is None and s.get("cancelledAt") is not None, s
              assert at(wd, 5300).get("lastBlock") == "seat-cancelled", st(wd)
              # re-armed after 30 min: warns again, not cancellable
              s = at(wd, 5000 + 1810)
              assert s["warning"]["n"] == 2 and not s["warning"]["cancellable"], s
              wd.send_chars("clear; selfheal cancel; echo rc=$?\n")
              wd.wait_until_tty_matches("2", "rc=1", timeout=60)
              assert st(wd).get("warning"), st(wd)
              assert boot_id(wd) == b0
              clock(wd, 5000 + 1810 + 301)
              reboot_tick(wd)
              a = actions(wd)
              assert a.get("cancel") == 1 and a.get("warn") == 2, a

      def rebooted(m):
          return m.execute("test -e /run/fake-rebooted")[0] == 0

      def peer_rounds(nodes_, times, check):
          for t in times:
              live = [m for m in nodes_ if not rebooted(m)]
              for m in live:
                  clock(m, t)
              ths = [threading.Thread(target=tick, args=(m,)) for m in live]
              for th in ths:
                  th.start()
              for th in ths:
                  th.join()
              check(t)

      if "d" in SUBTESTS:
          with subtest("(d) tang peer: down refuses until 6 h; just booted is never overridden"):
              # the forced command answers whatever is asked
              out = peera.succeed("${pkgs.openssh}/bin/ssh -n -i /etc/selfheal-peer-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@fe80::b%eth1 touch /tmp/pwned")
              info = json.loads(out.strip().splitlines()[-1])
              assert info["host"] == "peerb" and "uptime" in info, info
              peerb.fail("test -e /tmp/pwned")
              T = 100000
              clock(peerb, 5000)
              cut_anchor(peera)
              for t in (T, T + 60, T + 700):
                  at(peera, t)
              s = at(peera, T + 1000)
              assert s.get("lastBlock") == "peer-handshake", s
              peerb.succeed("systemctl stop sshd.service")
              s = at(peera, T + 1100)
              assert s.get("lastBlock") == "peer-down", s
              # the peer is back but booted just now: refused, even after 7 h
              peerb.succeed("systemctl start sshd.service")
              clock(peerb, -100000)
              s = at(peera, T + 7 * 3600)
              assert s.get("lastBlock") == "peer-recent", s
              assert not rebooted(peera)
              # down again, cut off > 6 h: the override
              clock(peerb, 5000)
              peerb.succeed("systemctl stop sshd.service")
              at(peera, T + 7 * 3600 + 60)
              assert rebooted(peera), st(peera)
              assert json.loads(peera.succeed("cat /var/lib/selfheal/watchdog/last-reboot.json"))["kind"] == "reboot"
              peerb.succeed("systemctl start sshd.service")
              heal(peera)

      if "i" in SUBTESTS:
          with subtest("(i) both peers cut off at once, ticked concurrently: one reboots, the other waits"):
              T2 = 200000
              for m in [peera, peerb]:
                  reset(m)
                  cut_anchor(m)

              def never_both(t):
                  assert not (rebooted(peera) and rebooted(peerb)), (t, st(peera), st(peerb))

              peer_rounds([peera, peerb], [T2, T2 + 60, T2 + 700, T2 + 1000, T2 + 1100, T2 + 1200, T2 + 1300], never_both)
              assert rebooted(peera) != rebooted(peerb), (st(peera), st(peerb))
              first, other = (peera, peerb) if rebooted(peera) else (peerb, peera)
              s = st(other)
              # it saw the first commit (peer-rebooting), then the first gone (peer-down)
              assert s.get("lastBlock") in ("peer-rebooting", "peer-down"), s
              assert any(e.get("gate") == "peer-rebooting" for e in events(other, "watchdog-reboot-blocked")), events(other, "watchdog-reboot-blocked")
              # first stays down (it "rebooted"): other waits for its override;
              # peerb (the later name) waits peerStagger (60 min) longer
              first.succeed("systemctl stop sshd.service")
              override = 6 * 3600 + (3600 if other is peerb else 0)
              s = at(other, T2 + override - 60)
              assert s.get("lastBlock") == "peer-down" and not rebooted(other), s
              at(other, T2 + override + 10)
              assert rebooted(other), st(other)
              first.succeed("systemctl start sshd.service")
              for m in [peera, peerb]:
                  heal(m)

      if "e" in SUBTESTS:
          with subtest("(e) laptop (roaming): report only"):
              b0 = boot_id(laptop)
              laptop.succeed("systemctl stop sshd.service mesh-standin.service")
              for i in range(13):
                  at(laptop, 4000 + i * 600)
              s = st(laptop)
              assert s["state"] == "services", s
              assert s.get("actions", {}) == {}, s
              laptop.fail("systemctl is-active sshd.service")
              metric(laptop, 'selfheal_watchdog_state{state="services"} 1')
              assert boot_id(laptop) == b0
    '';
}
