# A lingering user's manager killed with SIGKILL (as the OOM killer does)
# comes back on its own, with a reachable user bus; a clean stop stays
# stopped.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "user-manager-restart";

  nodes.machine = {
    imports = [ ./default.nix ];
    users.users.alice = {
      isNormalUser = true;
      linger = true;
    };
  };

  testScript = ''
    machine.wait_for_unit("user@1000.service")

    def main_pid():
        return machine.succeed("systemctl show -P MainPID user@1000.service").strip()

    with subtest("a killed manager restarts and serves its bus again"):
        old = main_pid()
        machine.succeed(f"kill -KILL {old}")
        machine.wait_until_succeeds(
            f"pid=$(systemctl show -P MainPID user@1000.service); "
            f"[ \"$pid\" != 0 ] && [ \"$pid\" != {old} ] && systemctl is-active user@1000.service",
            timeout=60,
        )
        machine.wait_until_succeeds("systemctl --user -M alice@ show-environment", timeout=60)

    with subtest("a clean stop stays stopped"):
        machine.succeed("systemctl stop user@1000.service")
        machine.sleep(10)
        machine.fail("systemctl is-active user@1000.service")
  '';
}
