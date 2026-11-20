# VM test of ./hardware-watchdog.nix (check self-heal-hardware-watchdog): a
# virtual i6300esb watchdog. (a) systemd opens it with the fleet's 30 s;
# (b) PID 1 stopped (ptrace-attached, so it can't ping) gets the machine
# reset by the device: qemu runs -no-reboot, so the reset ends the VM and
# the test boots it again and sees a new boot id.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "self-heal-hardware-watchdog";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ./default.nix ];
      hyper.selfHeal = {
        enable = true;
        deployGuard.enable = false;
      };
      virtualisation.qemu.options = [ "-device i6300esb" ];
      boot.kernelModules = [ "i6300esb" ];
      environment.systemPackages = [ pkgs.python3 ];
    };

  testScript = ''
    import datetime
    import time

    machine.wait_for_unit("multi-user.target")

    with subtest("systemd drives the watchdog with 30 s"):
        machine.succeed("test -c /dev/watchdog0")
        machine.wait_until_succeeds(
            "systemctl show -P RuntimeWatchdogUSec | grep -qx 30s",
            timeout=datetime.timedelta(seconds=30),
        )
        machine.succeed("systemctl show -P RebootWatchdogUSec | grep -qx 10min")
        machine.wait_until_succeeds(
            "grep -qx active /sys/class/watchdog/watchdog0/state",
            timeout=datetime.timedelta(seconds=30),
        )
        machine.succeed("grep -qx 30 /sys/class/watchdog/watchdog0/timeout")

    with subtest("a hung PID 1 gets the machine reset"):
        boot1 = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
        # PTRACE_ATTACH stops PID 1; the tracer holds it until the reset.
        machine.succeed(
            "systemd-run --unit=freeze-pid1 python3 -c '"
            "import ctypes, time; "
            "libc = ctypes.CDLL(None, use_errno=True); "
            "assert libc.ptrace(16, 1, None, None) == 0, ctypes.get_errno(); "
            "time.sleep(3600)'"
        )
        machine.wait_until_succeeds(
            "grep -q '^State:.*t (tracing stop)' /proc/1/status",
            timeout=datetime.timedelta(seconds=20),
        )
        machine.connected = False
        frozen = time.monotonic()
        machine.wait_for_shutdown(timeout=datetime.timedelta(seconds=120))
        took = time.monotonic() - frozen
        # pings come every <= 15 s, so the 30 s timer fires 15-30 s after
        # the freeze; an earlier exit is something else (panic=1 also ends
        # the VM), 50 s leaves slack for a slow host
        assert 15 <= took <= 50, f"VM ended {took:.0f} s after the freeze"
        machine.start()
        machine.wait_for_unit("multi-user.target")
        boot2 = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
        assert boot1 != boot2, "no reset"
  '';
}
