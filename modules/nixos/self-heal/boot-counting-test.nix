# VM test of ./boot-counting.nix (check self-heal-boot-counting), modelled on
# nixpkgs' nixos/tests/systemd-boot.nix bootCounting test. One VM booted
# through systemd-boot (qemu -no-reboot: a reboot ends the VM, the test
# starts it again). Generations, all on the same disk:
#   A = `machine` (healthy), B = `bad` (sshd off: the local health gate
#   fails), C = `slow` (an initrd unit stands in for a root unlock wait),
#   T = `tang` (sshd off, with a Tang peer: node `peer`, a TCP 7654
#   listener at fe80::7a6e:9 on the test VLAN), U = `nolink` (the uplink
#   down: no default gateway; 60 s gate).
# Shortened gate: 30 s timeout, 2 s interval.
{ pkgs }:
let
  base =
    { lib, ... }:
    {
      imports = [ ./default.nix ];
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      virtualisation.memorySize = 1024;
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      system.switch.enable = true;
      nix.enable = true;
      # persisted machine-id across reboots (nixos/tests/systemd-boot.nix)
      environment.etc."machine-id".text = "1234567890abcdef1234567890abcdef\n";
      # the hostname is in the toplevel: one name for every generation
      networking.hostName = lib.mkForce "target";
      # qemu's user network: 10.0.2.2 is the default gateway
      networking.interfaces.eth0.useDHCP = true;
      services.openssh.enable = true;
      hyper.selfHeal = {
        enable = true;
        anchors = [ ];
        bootHealth = {
          timeout = 30;
          interval = 2;
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "self-heal-boot-counting";

  nodes.machine =
    { nodes, ... }:
    {
      imports = [ base ];
      system.extraDependencies = [
        nodes.bad.system.build.toplevel
        nodes.slow.system.build.toplevel
        nodes.tang.system.build.toplevel
        nodes.nolink.system.build.toplevel
      ];
    };

  nodes.bad =
    { lib, ... }:
    {
      imports = [ base ];
      services.openssh.enable = lib.mkForce false;
    };

  nodes.tang =
    { lib, pkgs, ... }:
    {
      imports = [
        base
        # stands in for ../tang-server.nix (the gate's assertion wants a
        # Tang server next to tangPeers)
        # (nested form, so tools/repo-map does not list the stub as a declaration)
        { options = { hyper.tangServer.enable = lib.mkOption { default = true; }; }; }
      ];
      # sshd installed but not started at boot: the gate fails on it, and
      # a subtest can start it later (a boot that recovers)
      systemd.services.sshd.wantedBy = lib.mkForce [ ];
      hyper.selfHeal.bootHealth = {
        tangPeers = [
          {
            address = "fe80::7a6e:9";
            dev = "eth1";
          }
        ];
        tangPollInterval = 5;
        tangPollTimeout = 40;
        tangWithdraw = 10;
      };
      # this machine's own Tang (som/vit serve each other): a stand-in
      # socket the gate withdraws before it restarts
      systemd.sockets.tangd = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "7654" ];
        socketConfig.Accept = true;
      };
      systemd.services."tangd@".serviceConfig = {
        ExecStart = "${pkgs.coreutils}/bin/true";
        StandardInput = "socket";
      };
    };

  nodes.nolink =
    { lib, pkgs, ... }:
    {
      imports = [ base ];
      networking.interfaces.eth0.useDHCP = lib.mkForce false;
      hyper.selfHeal.bootHealth.timeout = lib.mkForce 60;
      # the uplink is down (a broken network change); eth1 is the test VLAN
      systemd.services.uplink-down = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        before = [ "selfheal-boot-healthy.service" ];
        serviceConfig.Type = "oneshot";
        path = [ pkgs.iproute2 ];
        script = "ip link set eth0 down";
      };
    };

  # Stands in for som/vit's Tang: anything answering TCP 7654.
  nodes.peer =
    { pkgs, ... }:
    {
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = "fe80::7a6e:9";
          prefixLength = 64;
        }
      ];
      networking.firewall.allowedTCPPorts = [ 7654 ];
      systemd.services.tang-standin = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 7654 --bind ::";
      };
    };

  nodes.slow = {
    imports = [ base ];
    # Waits in stage 1, before the root is mounted, like vit's LUKS/tang
    # and som's ZFS unlock; prints the counted entry systemd-boot picked.
    boot.initrd.systemd.services.unlock-standin = {
      wantedBy = [ "initrd-root-fs.target" ];
      before = [
        "sysroot.mount"
        "initrd-root-fs.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
      };
      script = ''
        entry=$(tr -cd '[:print:]' < /sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f 2>/dev/null || echo none)
        echo "unlock-standin: waiting for the key, entry $entry"
        for _ in $(seq 15); do sleep 1; done
      '';
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import datetime
      import json
      import re

      A = "${nodes.machine.system.build.toplevel}"
      B = "${nodes.bad.system.build.toplevel}"
      C = "${nodes.slow.system.build.toplevel}"
      T = "${nodes.tang.system.build.toplevel}"
      U = "${nodes.nolink.system.build.toplevel}"
      COUNT = "/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

      def secs(n):
          return datetime.timedelta(seconds=n)

      def entry(gen):
          """The entry file of generation `gen` (its name carries the counter)."""
          out = machine.succeed(f"grep -l '^version Generation {gen} ' /boot/loader/entries/nixos-*.conf").split()
          assert len(out) == 1, out
          return out[0].rsplit("/", 1)[-1]

      def counter(gen):
          """empty = blessed, else '+2', '+1-1', '+0-2' ..."""
          m = re.fullmatch(r"nixos-[0-9a-f]+((\+[0-9]+(-[0-9]+)?)?)\.conf", entry(gen))
          assert m, entry(gen)
          return m.group(1)

      def check(gen, want):
          got = counter(gen)
          assert got == want, f"generation {gen}: {entry(gen)}, want counter '{want}'"

      def current():
          return machine.succeed("readlink -f /run/current-system").strip()

      def boot_id():
          return machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()

      def events(kind):
          rc, o = machine.execute("cat /var/lib/selfheal/log.jsonl")
          return [e for e in (json.loads(x) for x in o.splitlines()) if e["event"] == kind] if rc == 0 else []

      def set_profile(gen_path):
          """clan's first two steps: profile, then `switch-to-configuration boot`."""
          machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {gen_path}")
          machine.succeed(f"{gen_path}/bin/switch-to-configuration boot")

      def reboot():
          machine.shutdown()
          machine.start()

      def rebooted_itself(timeout=180):
          """The gate's `systemctl reboot` ends the VM (-no-reboot)."""
          machine.wait_for_shutdown(timeout=secs(timeout))
          machine.start()

      def up():
          machine.wait_for_unit("multi-user.target")

      def blessed_boot():
          machine.wait_for_unit("systemd-bless-boot.service")
          machine.succeed("systemctl is-active selfheal-boot-healthy.service")
          st = machine.succeed("$(dirname $(readlink -f $(command -v systemctl)))/../lib/systemd/systemd-bless-boot status").strip()
          assert st == "good", st

      def no_more_reboots():
          """A blessed/uncounted boot: the gate is not even in the transaction
          and refuses on its own; the boot outlives a full gate timeout."""
          b0 = boot_id()
          machine.fail(f"test -e {COUNT}")
          assert machine.succeed("systemctl show -P ActiveState selfheal-boot-healthy.service").strip() == "inactive"
          assert machine.succeed("systemctl show -P ActiveState boot-complete.target").strip() == "inactive"
          machine.wait_until_succeeds("test $(cut -d. -f1 /proc/uptime) -ge 50", timeout=120)
          assert boot_id() == b0, "rebooted"

      machine.start()
      up()

      with subtest("(a) a healthy generation is blessed"):
          machine.succeed(f"test -e {COUNT}")
          blessed_boot()
          check(1, "")
          assert current() == A
          assert events("boot-healthy"), "no boot-healthy event"
          machine.wait_for_unit("selfheal-boot.service")
          machine.succeed("grep -x 'selfheal_boot_fallback 0' /run/selfheal/boot-fallback.prom")
          machine.succeed("grep -x 'selfheal_boot_health_ok 1' /run/selfheal/boot.prom")

      with subtest("(b) an unhealthy generation reboots itself twice, then A boots and stays"):
          set_profile(B)
          check(1, "")
          check(2, "+2")
          reboot()
          up()
          assert current() == B
          check(2, "+1-1")
          rebooted_itself()
          up()
          assert current() == B
          check(2, "+0-2")
          rebooted_itself()
          up()
          assert current() == A, "did not fall back to A"
          check(1, "")
          check(2, "+0-2")
          tried = [e for e in events("boot-unhealthy") if e.get("reboot") == "yes"]
          assert len(tried) == 2 and all("sshd" in e["failing"] for e in tried), tried
          machine.wait_for_unit("selfheal-boot.service")
          machine.succeed("grep -x 'selfheal_boot_fallback 1' /run/selfheal/boot-fallback.prom")
          assert events("boot-fallback"), "no boot-fallback event"
          # Even an unhealthy blessed boot never reboots from here.
          machine.succeed("systemctl stop sshd.service")
          out = machine.succeed("selfheal boot-health 2>&1")
          assert "bless status clean" in out, out
          machine.succeed("systemctl start sshd.service")
          no_more_reboots()

      with subtest("deploy guard's rollback: prev as a fresh +2 entry, blessed"):
          # the guard runs `nix-env --set <prev>` + `<prev>/bin/switch-to-configuration boot`
          set_profile(A)
          check(3, "+2")
          reboot()
          up()
          assert current() == A
          blessed_boot()
          check(3, "")
          machine.wait_for_unit("selfheal-boot.service")
          machine.succeed("grep -x 'selfheal_boot_fallback 0' /run/selfheal/boot-fallback.prom")

      with subtest("selfheal hold: an unhealthy boot does not reboot"):
          machine.succeed("selfheal hold 60")
          set_profile(B)
          check(4, "+2")
          reboot()
          up()
          assert current() == B
          b0 = boot_id()
          machine.wait_until_succeeds(
              "grep -q '\"event\": \"boot-unhealthy\".*held until' /var/lib/selfheal/log.jsonl",
              timeout=120,
          )
          held = [e for e in events("boot-unhealthy") if e.get("reboot") == "no"]
          assert held and "held until" in held[-1]["why"], held
          machine.wait_until_succeeds("systemctl is-failed selfheal-boot-healthy.service", timeout=30)
          machine.fail("systemctl is-active systemd-bless-boot.service")
          assert boot_id() == b0
          check(4, "+1-1")
          machine.succeed("selfheal release")
          # the next try is not held: it reboots itself, then falls back
          reboot()
          up()
          assert current() == B
          check(4, "+0-2")
          rebooted_itself()
          up()
          assert current() == A
          check(3, "")
          check(4, "+0-2")

      with subtest("(c) power-cycles at the unlock prompt spend the tries, then the older entry boots"):
          set_profile(C)
          check(5, "+2")
          stem = entry(5)[: -len("+2.conf")]
          reboot()
          machine.wait_for_console_text(re.escape(stem) + r"\+1-1\.conf")
          machine.crash()
          machine.start()
          machine.wait_for_console_text(re.escape(stem) + r"\+0-2\.conf")
          machine.crash()
          machine.start()
          up()
          # newest entry that is not bad: generation 3 (A, blessed); it
          # needs the same key as C would
          assert current() == A, current()
          check(5, "+0-2")
          no_more_reboots()

      with subtest("(c) a long unlock wait costs nothing: one try, blessed"):
          # the profile already points at C (generation 5): a new generation
          # needs another system in between (nix-env --set to the same path
          # adds none)
          set_profile(A)  # generation 6
          set_profile(C)  # generation 7, a fresh +2 entry
          check(7, "+2")
          stem = entry(7)[: -len("+2.conf")]
          reboot()
          machine.wait_for_console_text(re.escape(stem) + r"\+1-1\.conf")
          up()
          assert current() == C
          blessed_boot()
          check(7, "")

      with subtest("roaming laptops: no gateway needed at boot; local level still needs it"):
          wrapper = re.search(r"exec (\S+) --config (\S+)", machine.succeed("cat $(command -v selfheal)"))
          assert wrapper, "no exec line in the selfheal wrapper"
          script, conf = wrapper.groups()
          machine.succeed(f"sed 's/\"bootRequireGateway\":true/\"bootRequireGateway\":false/' {conf} > /tmp/roaming.json")
          machine.succeed("grep -q '\"bootRequireGateway\":false' /tmp/roaming.json")
          # offline: the uplink down (eth1, the test VLAN, stays up)
          machine.succeed("ip link set eth0 down")
          machine.wait_until_fails("ip route show default | grep -q . || ip -6 route show default | grep -q .", timeout=30)
          h = json.loads(machine.succeed(f"{script} --config /tmp/roaming.json health --level boot --json"))
          assert h["healthy"] and all(i["name"].split(":")[0] == "sshd" for i in h["items"]), h
          rc, o = machine.execute(f"{script} --config /tmp/roaming.json health --level local --json")
          h = json.loads(o)
          assert rc == 1 and not h["healthy"] and "no default route" in json.dumps(h), h
          rc, _ = machine.execute("selfheal health --level boot")
          assert rc == 1, "the fleet default needs the gateway"
          machine.succeed("ip link set eth0 up")

      def unhealthy_events():
          return events("boot-unhealthy")

      def tangd_active():
          return machine.execute("systemctl is-active --quiet tangd.socket")[0] == 0

      with subtest("tang peers: two-phase check, simultaneous gates both stay up"):
          # The peer answers when the gate expires; while we have withdrawn
          # our own Tang the peer goes away too (its gate restarting at the
          # same moment): the re-check blocks, our Tang comes back, we poll
          # the peer, then give up and stay up.
          peer.start()
          peer.wait_for_unit("tang-standin.service")
          peer.wait_for_open_port(7654)
          set_profile(T)  # generation 8
          check(8, "+2")
          n0 = len(unhealthy_events())
          reboot()
          up()
          assert current() == T
          b0 = boot_id()
          machine.wait_until_succeeds("timeout 3 bash -c 'exec 3<>/dev/tcp/fe80::7a6e:9%eth1/7654'", timeout=60)
          assert tangd_active()
          machine.wait_until_succeeds("! systemctl is-active --quiet tangd.socket", timeout=90)
          peer.crash()
          machine.wait_until_succeeds("systemctl is-active --quiet tangd.socket", timeout=30)
          assert events("boot-unhealthy-waiting"), "no polling"
          machine.wait_until_succeeds("systemctl is-failed selfheal-boot-healthy.service", timeout=120)
          e = unhealthy_events()[n0:]
          assert len(e) == 1 and e[0]["reboot"] == "no" and "no tang peer answers" in e[0]["why"], e
          assert boot_id() == b0
          assert tangd_active()
          check(8, "+1-1")

      with subtest("tang peers: polling finds the peer back and restarts"):
          n1 = len(events("boot-unhealthy-waiting"))
          reboot()
          up()
          assert current() == T
          check(8, "+0-2")
          machine.wait_until_succeeds(
              f"test $(grep -c '\"event\": \"boot-unhealthy-waiting\"' /var/lib/selfheal/log.jsonl) -gt {n1}",
              timeout=90,
          )
          peer.start()
          peer.wait_for_unit("tang-standin.service")
          rebooted_itself()
          up()
          e = unhealthy_events()[n0:]
          assert len(e) == 2 and e[1]["reboot"] == "yes", e
          # newest entry that is not bad: C (generation 7)
          assert current() == C, current()
          peer.crash()

      with subtest("uplink down: the gateway check fails and it reboots"):
          set_profile(U)  # generation 9
          check(9, "+2")
          n0 = len(unhealthy_events())
          reboot()
          up()
          assert current() == U
          rebooted_itself()
          up()
          e = unhealthy_events()[n0:]
          assert len(e) == 1 and e[0]["reboot"] == "yes" and "no default route" in e[0]["failing"], e
          assert current() == U
          check(9, "+0-2")

      with subtest("a running switch blocks the reboot"):
          # second try of U, its gate still running (60 s): a deploy starts
          b0 = boot_id()
          machine.succeed("systemd-run --unit=clan-switch-target-standin sleep 600")
          machine.wait_until_succeeds("systemctl is-failed selfheal-boot-healthy.service", timeout=120)
          e = unhealthy_events()[n0:]
          assert len(e) == 2 and e[1]["reboot"] == "no" and "a switch is running" in e[1]["why"], e
          assert boot_id() == b0
          machine.succeed("systemctl stop clan-switch-target-standin")

      with subtest("a redeploy of the profile gives its bad entry fresh tries"):
          machine.wait_for_unit("selfheal-boot.service")
          # booted == profile, but the profile's entry is bad: the next boot
          # would take an older entry
          machine.succeed("grep -x 'selfheal_boot_fallback 1' /run/selfheal/boot-fallback.prom")
          machine.succeed(f"{U}/bin/switch-to-configuration switch")
          check(9, "+2")
          assert events("boot-entry-retry"), "no boot-entry-retry event"
          machine.succeed("grep -x 'selfheal_boot_fallback 0' /run/selfheal/boot-fallback.prom")

      with subtest("tang wait: a boot that recovers meanwhile is blessed, never restarted"):
          set_profile(T)  # generation 10, a fresh +2 entry (peer down)
          check(10, "+2")
          n0 = len(unhealthy_events())
          w0 = len(events("boot-unhealthy-waiting"))
          h0 = len(events("boot-healthy"))
          reboot()
          up()
          assert current() == T
          b0 = boot_id()
          machine.wait_until_succeeds(
              f"test $(grep -c '\"event\": \"boot-unhealthy-waiting\"' /var/lib/selfheal/log.jsonl) -gt {w0}",
              timeout=90,
          )
          machine.succeed("systemctl start sshd.service")
          peer.start()
          peer.wait_for_unit("tang-standin.service")
          machine.wait_until_succeeds("systemctl is-active selfheal-boot-healthy.service", timeout=60)
          machine.wait_for_unit("systemd-bless-boot.service")
          healthy = events("boot-healthy")[h0:]
          assert len(healthy) == 1 and healthy[0].get("after") == "tang wait", healthy
          assert [e for e in unhealthy_events()[n0:] if e.get("reboot") == "yes"] == [], unhealthy_events()[n0:]
          assert boot_id() == b0
          check(10, "")
          machine.succeed("systemctl is-active tangd.socket")
          peer.crash()
    '';
}
