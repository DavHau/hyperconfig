# VM test of ./deploy-guard.nix (check self-heal-deploy-guard): a target
# booted through systemd-boot (real reboots: qemu runs -no-reboot, so a
# reboot is wait_for_shutdown + start), an anchor standing in for the mesh
# peers, and `mesh-standin` for the mesh daemons. Generations are A (the
# booted system) and its specialisations: B breaks the network when the
# switch starts it (stops sshd and the mesh stand-in, takes eth1 down; A
# has no such unit), good1/good2 (C) change a file only. Every switch runs
# like clan's (nix-env --set, then systemd-run units clan-boot-*/clan-switch-*).
# The deadline is shortened to 60 s.
{ pkgs }:
let
  inherit (pkgs) lib;
in
pkgs.testers.runNixOSTest {
  name = "self-heal-deploy-guard";

  # eth1 (vlan 1) stands in for the overlays, eth2 (vlan 2) for the public
  # internet side: the anchor's eth2 address is its "public" address, and
  # the slirp gateway on eth0 (10.0.2.2) the internet probe.
  nodes.anchor = {
    virtualisation.vlans = [
      1
      2
    ];
    services.openssh.enable = true;
  };

  nodes.target =
    {
      config,
      nodes,
      pkgs,
      ...
    }:
    {
      imports = [ ./default.nix ];
      networking.hostName = "target";
      virtualisation.vlans = [
        1
        2
      ];

      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      virtualisation.memorySize = 1536;
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      system.switch.enable = true;
      nix.enable = true;
      # persisted machine-id across reboots (nixos/tests/systemd-boot.nix)
      environment.etc."machine-id".text = "1234567890abcdef1234567890abcdef\n";

      services.openssh.enable = true;
      environment.systemPackages = [ pkgs.e2fsprogs ];

      systemd.services.mesh-standin = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };

      hyper.selfHeal = {
        enable = true;
        anchors = [ nodes.anchor.networking.primaryIPAddress ];
        anchorsPublic = [ (lib.head nodes.anchor.networking.interfaces.eth2.ipv4.addresses).address ];
        internetProbes = [ "10.0.2.2" ];
        meshUnits = [ "mesh-standin.service" ];
        deployGuard = {
          deadline = 60;
          restoreWindow = 30;
          extendStep = 20;
          maxExtend = 150;
          stableChecks = 2;
        };
      };

      specialisation.broken.configuration = {
        environment.etc."generation".text = "broken";
        # Started by the switch into B: cuts the machine off the way the
        # 2026-11-19 switch did, and keeps it off: both links stay down
        # (eth0 too, so the gateway is gone and it is no upstream outage;
        # the driver's shell runs over virtconsole, not eth0).
        systemd.services.break-network = {
          wantedBy = [ "multi-user.target" ];
          path = [
            pkgs.iproute2
            config.systemd.package
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            systemctl stop --no-block sshd.service mesh-standin.service
            ip link set eth1 down
            ip link set eth0 down
          '';
        };
      };
      specialisation.good1.configuration.environment.etc."generation".text = "good1";
      specialisation.good2.configuration.environment.etc."generation".text = "good2";
      # Cuts only the overlays (eth1), like a firewall/route/mesh-config
      # change: sshd and the mesh daemons stay up, gateway, internet and the
      # anchor's public address (eth2) answer. A local fault: rolled back.
      specialisation.overlaycut.configuration = {
        environment.etc."generation".text = "overlaycut";
        systemd.services.cut-overlay = {
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.iproute2 ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = "ip link set eth1 down";
        };
      };
      # A laptop (hyper.selfHeal.roaming): offline is upstream.
      specialisation.roam.configuration = {
        environment.etc."generation".text = "roam";
        hyper.selfHeal.roaming = true;
      };
    };

  testScript =
    { nodes, ... }:
    let
      a = nodes.target.system.build.toplevel;
      anchorPublic = (lib.head nodes.anchor.networking.interfaces.eth2.ipv4.addresses).address;
    in
    ''
      import datetime
      import json

      A = "${a}"
      B = f"{A}/specialisation/broken"
      C1 = f"{A}/specialisation/good1"
      C2 = f"{A}/specialisation/good2"
      OC = f"{A}/specialisation/overlaycut"
      R = f"{A}/specialisation/roam"

      def secs(n):
          return datetime.timedelta(seconds=n)

      def realp(p):
          return target.succeed(f"readlink -f {p}").strip()

      A, B, C1, C2, OC, R = realp(A), realp(B), realp(C1), realp(C2), realp(OC), realp(R)
      n = 0

      def clan_switch(gen, expect=True):
          """clan_lib/machines/update.py's steps; returns (ok, output)."""
          global n
          n += 1
          target.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {gen}")
          out = ""
          for action in ["boot", "switch"]:
              cmd = (f"systemd-run --wait --verbose --output=cat --collect --no-ask-password "
                     f"--service-type=exec --unit=clan-{action}-target-{n:08x}.service "
                     f"-- {gen}/bin/switch-to-configuration {action} 2>&1")
              rc, o = target.execute(cmd)
              out += o
              if rc != 0:
                  assert not expect, f"{action} to {gen} failed: {o}"
                  return False, out
          assert expect, f"switch to {gen} should have failed: {out}"
          return True, out

      def current():
          return realp("/run/current-system")

      def pending():
          rc, o = target.execute("cat /var/lib/selfheal/deploy-guard/pending.json")
          return json.loads(o) if rc == 0 else None

      def timers():
          return target.succeed("systemctl list-units --all --plain --no-legend 'selfheal-deploy-guard-*.timer' | awk '{print $1}'").split()

      def events():
          rc, o = target.execute("cat /var/lib/selfheal/log.jsonl")
          return [json.loads(x) for x in o.splitlines()] if rc == 0 else []

      def wait_event(kind, since, timeout, **match):
          def ok(_):
              return any(e["event"] == kind and all(str(e.get(k)) == str(v) for k, v in match.items())
                         for e in events()[since:])
          retry(ok, timeout=secs(timeout))

      def boot_id():
          return target.succeed("cat /proc/sys/kernel/random/boot_id").strip()

      def anchor_down():
          """The anchors gone on every address (overlay eth1, public eth2)."""
          anchor.succeed("ip link set eth1 down; ip link set eth2 down")

      def anchor_up():
          anchor.succeed("ip link set eth1 up; ip link set eth2 up")

      def reboot_happened(timeout):
          target.wait_for_shutdown(timeout=secs(timeout))
          target.start()
          target.wait_for_unit("multi-user.target")

      start_all()
      anchor.wait_for_unit("sshd.service")
      target.wait_for_unit("multi-user.target")
      target.wait_for_unit("sshd.service")
      target.wait_for_unit("mesh-standin.service")
      assert current() == A

      with subtest("health: sshd, mesh stand-in, anchor"):
          target.wait_until_succeeds("selfheal health", timeout=60)
          h = json.loads(target.succeed("selfheal health --json"))
          assert h["healthy"] and {i["name"] for i in h["items"]} == {"sshd", "sshd:22", "mesh:mesh-standin.service", "anchors"}, h
          target.succeed("selfheal health --level local")

      with subtest("a broken guard never blocks the switch"):
          # pending.json can't be written, so arming fails
          target.succeed("mkdir -p /var/lib/selfheal/deploy-guard && chattr +i /var/lib/selfheal/deploy-guard")
          ok, out = clan_switch(C1)
          assert current() == C1
          assert "selfheal: arm-failed" in out, out
          assert timers() == [], timers()
          target.succeed("chattr -i /var/lib/selfheal/deploy-guard")

      with subtest("a no-op switch arms nothing"):
          ok, out = clan_switch(C1)
          assert "nothing to guard" in out, out
          assert pending() is None and timers() == []

      with subtest("good switch, confirmed by selfheal confirm"):
          b0 = boot_id()
          clan_switch(C2)
          p = pending()
          assert p and p["prev"] == C1 and p["new"] == C2, p
          # the transient timer survived the switch, from /run, not /etc
          [tm] = timers()
          frag = target.succeed(f"systemctl show -P FragmentPath {tm}").strip()
          assert frag.startswith("/run/systemd/transient/"), frag
          target.succeed("selfheal confirm")
          assert pending() is None and timers() == [], (pending(), timers())
          target.succeed("grep -x 'selfheal_deploy_guard_pending 0' /run/selfheal/selfheal.prom")
          target.succeed("grep -x 'selfheal_deploy_guard_last_confirm_timestamp_seconds [0-9]*' /run/selfheal/selfheal.prom")
          assert boot_id() == b0

      with subtest("good switch, confirmed by its timer"):
          b0 = boot_id()
          since = len(events())
          clan_switch(C1)
          assert pending() is not None
          # a nixpkgs bump with a new systemd re-executes PID 1 mid-switch
          target.succeed("systemctl daemon-reexec")
          assert len(timers()) == 1, timers()
          wait_event("confirmed", since, 150, how="timer")
          assert pending() is None
          assert current() == C1 and boot_id() == b0
          target.fail("test -e /var/lib/selfheal/deploy-guard/rolled-back")

      with subtest("healthy, but the switch still runs: confirmed only after it ended"):
          since = len(events())
          clan_switch(C2)
          # a long switch: still running at the 60 s deadline
          target.succeed("systemd-run --unit=clan-switch-target-fe.service sleep 75")
          wait_event("rearm", since, 120)
          assert "healthy, but the switch still runs" in [e for e in events()[since:] if e["event"] == "rearm"][-1]["why"]
          assert pending() is not None
          wait_event("confirmed", since, 90, how="timer")
          target.fail("systemctl is-active clan-switch-target-fe.service")

      with subtest("upstream-only outage: no restore, no reboot, confirmed how=upstream"):
          b0 = boot_id()
          since = len(events())
          clan_switch(C1)
          # the anchors are cut off upstream on every address (overlay eth1,
          # public eth2); own link, gateway and internet (eth0) still fine
          anchor_down()
          wait_event("rearm", since, 120)
          assert "upstream" in [e for e in events()[since:] if e["event"] == "rearm"][-1]["why"]
          # maxExtend (150 s) after arming
          wait_event("confirmed", since, 240, how="upstream")
          kinds = [e["event"] for e in events()[since:]]
          assert "restore" not in kinds and "unhealthy" not in kinds, kinds
          assert pending() is None and boot_id() == b0 and current() == C1
          target.fail("test -e /var/lib/selfheal/deploy-guard/rolled-back")
          anchor_up()
          target.wait_until_succeeds("selfheal health", timeout=60)

      with subtest("roaming laptop offline (no route, anchors down): confirmed how=upstream"):
          b0 = boot_id()
          since = len(events())
          clan_switch(R)
          anchor_down()
          target.succeed("systemctl stop dhcpcd.service; while ip route del default; do :; done; while ip -6 route del default; do :; done; true")
          target.fail("selfheal health --level local")
          wait_event("rearm", since, 120)
          assert "roaming" in [e for e in events()[since:] if e["event"] == "rearm"][-1]["why"]
          wait_event("confirmed", since, 240, how="upstream")
          kinds = [e["event"] for e in events()[since:]]
          assert "restore" not in kinds and "unhealthy" not in kinds, kinds
          assert boot_id() == b0 and current() == R
          anchor_up()
          target.succeed("systemctl start dhcpcd.service")
          target.wait_until_succeeds("selfheal health --level local", timeout=60)
          clan_switch(C1)
          target.wait_until_succeeds("selfheal confirm", timeout=60)

      with subtest("a unit dead before the switch is not judged"):
          b0 = boot_id()
          target.succeed("systemctl stop mesh-standin.service")
          since = len(events())
          clan_switch(C2)
          p = pending()
          assert "mesh:mesh-standin.service" not in p["baseline"] and "sshd" in p["baseline"], p
          target.succeed("selfheal status | grep -q 'judged items (healthy when armed): sshd, sshd:22, anchors'")
          wait_event("confirmed", since, 150, how="timer")
          kinds = [e["event"] for e in events()[since:]]
          assert "restore" not in kinds, kinds
          assert boot_id() == b0
          target.succeed("systemctl start mesh-standin.service")

      with subtest("a pending deploy survives a reboot"):
          clan_switch(C1)
          p0 = pending()
          target.shutdown()
          target.start()
          target.wait_for_unit("multi-user.target")
          assert current() == C1
          target.wait_for_unit("selfheal-boot.service")
          p = pending()
          assert p and p["new"] == C1 and p["bootId"] == boot_id() != p0["bootId"], (p0, p)
          assert len(timers()) == 1
          target.succeed("selfheal confirm")
          clan_switch(A)
          target.succeed("selfheal confirm")
          assert current() == A and pending() is None

      with subtest("overlays cut, gateway + internet + anchor's public address answer: rolled back"):
          # the public branch probes TCP 22 only: the anchor serves it on eth2
          target.succeed("timeout 3 bash -c '</dev/tcp/${anchorPublic}/22'")
          since = len(events())
          clan_switch(OC)
          wait_event("local-overlay-fault", since, 120)
          wait_event("restore", since, 30)
          reboot_happened(300)
          assert current() == A, current()
          fl = json.loads(target.succeed("cat /var/lib/selfheal/deploy-guard/rolled-back"))
          assert fl["from"] == OC and fl["to"] == A and fl["reason"] == "anchors", fl
          kinds = [e["event"] for e in events()[since:]]
          assert "confirmed" not in kinds and kinds.index("restore") < kinds.index("rolled-back"), kinds
          target.succeed("selfheal clear")
          target.wait_until_succeeds("selfheal health", timeout=60)

      with subtest("lose the network mid-switch: restore, then roll back and reboot"):
          since = len(events())
          clan_switch(B)
          assert current() == B
          target.wait_until_succeeds("! systemctl is-active sshd.service", timeout=30)
          p = pending()
          assert p["prev"] == A and p["new"] == B, p
          # deadline: 60 s after arming
          wait_event("restore", since, 120)
          target.succeed("selfheal status | grep -q ' restore '")
          target.wait_until_succeeds("systemctl is-active sshd.service mesh-standin.service", timeout=20)
          reboot_happened(300)
          assert current() == A, current()
          assert realp("/nix/var/nix/profiles/system") == A
          fl = json.loads(target.succeed("cat /var/lib/selfheal/deploy-guard/rolled-back"))
          assert fl["from"] == B and fl["to"] == A and fl["bootEntry"], fl
          assert fl["reason"] == "anchors", fl
          target.wait_for_unit("selfheal-boot.service")
          target.succeed("grep -x 'selfheal_deploy_guard_rolled_back{reason=\"anchors\"} 1' /run/selfheal/selfheal.prom")
          target.succeed("grep -x 'selfheal_deploy_guard_pending 0' /run/selfheal/selfheal.prom")
          kinds = [e["event"] for e in events()[since:]]
          assert kinds.index("restore") < kinds.index("rolled-back"), kinds
          target.fail("systemctl cat break-network.service")

      with subtest("after a rollback, deploys are refused until selfheal clear"):
          assert target.execute("selfheal status --blocked")[0] == 3
          ok, out = clan_switch(B, expect=False)
          assert "selfheal: target rolled back" in out and "run `selfheal clear` on target" in out, out
          assert current() == A
          target.succeed("selfheal clear")
          target.succeed("selfheal status --blocked")
          target.succeed("grep -x 'selfheal_deploy_guard_rolled_back 0' /run/selfheal/selfheal.prom")
          # lifted: the boot step passes again (profile back to A)
          target.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {A}")
          target.succeed(f"{A}/bin/switch-to-configuration boot")

      with subtest("hold: no restore, no rollback; release lets it roll back"):
          target.succeed("selfheal hold 10")
          since = len(events())
          b0 = boot_id()
          clan_switch(B)
          target.wait_until_succeeds("! systemctl is-active sshd.service", timeout=30)
          wait_event("rearm", since, 150)
          assert "hold" in [e for e in events()[since:] if e["event"] == "rearm"][-1]["why"]
          assert pending()["new"] == B
          assert "restore" not in [e["event"] for e in events()[since:]]
          target.fail("systemctl is-active sshd.service")
          assert boot_id() == b0
          target.succeed("selfheal release")
          wait_event("restore", since, 90)
          reboot_happened(300)
          assert current() == A
          target.succeed("test -e /var/lib/selfheal/deploy-guard/rolled-back")
          target.succeed("selfheal clear")

      with subtest("hung switch: restore at the first deadline, roll back only after maxExtend"):
          target.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {A}")
          target.succeed(f"{A}/bin/switch-to-configuration boot")
          since = len(events())
          clan_switch(B)
          # a clan switch unit that never finishes (the 2026-11-19 picture)
          target.succeed("systemd-run --unit=clan-switch-target-ff.service sleep infinity")
          wait_event("restore", since, 120)
          ev = events()[since:]
          armed = [e for e in ev if e["event"] == "armed"][-1]
          restore = [e for e in ev if e["event"] == "restore"][0]
          d = (datetime.datetime.fromisoformat(restore["time"]) - datetime.datetime.fromisoformat(armed["time"])).total_seconds()
          assert d < 90, (armed, restore)
          target.succeed("systemctl is-active clan-switch-target-ff.service")
          wait_event("rearm", since, 90)
          assert "switch still running" in [e for e in events()[since:] if e["event"] == "rearm"][-1]["why"]
          reboot_happened(300)
          assert current() == A
          fl = json.loads(target.succeed("cat /var/lib/selfheal/deploy-guard/rolled-back"))
          assert any("clan-switch-target-ff" in x for x in fl["notes"]), fl
          kinds = [e["event"] for e in events()[since:]]
          assert kinds.count("restore") == 1, kinds
          target.succeed("selfheal clear")
    '';
}
