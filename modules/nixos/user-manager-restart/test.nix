# A lingering user's manager killed with SIGKILL (as the OOM killer does)
# comes back on its own, with a reachable user bus; a clean stop stays
# stopped.
#
# A container test (systemd-nspawn, no VM): a unit's restart policy needs
# no kernel of its own. The Nix sandbox allows no setuid bits, so
# pam_unix's helper (unix_chkpwd) can't run and the systemd-user PAM stack
# is reduced to permit + pam_systemd (hyperhermes/checks/container-pam.nix). The user bus is
# dialled as the user at /run/user/1000/bus: `systemctl --user -M alice@`
# goes through machined, which the container doesn't run.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "user-manager-restart";

  containers.machine =
    { lib, pkgs, ... }:
    {
      imports = [
        ./default.nix
        ../../../hyperhermes/checks/container-pam.nix
      ];
      users.users.alice = {
        isNormalUser = true;
        linger = true;
      };
    };

  testScript = ''
    import datetime

    machine.wait_for_unit("user@1000.service")

    def main_pid():
        return machine.succeed("systemctl show -P MainPID user@1000.service").strip()

    user_bus = "runuser -u alice -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment"

    with subtest("a killed manager restarts and serves its bus again"):
        old = main_pid()
        machine.succeed(f"kill -KILL {old}")
        machine.wait_until_succeeds(
            f"pid=$(systemctl show -P MainPID user@1000.service); "
            f"[ \"$pid\" != 0 ] && [ \"$pid\" != {old} ] && systemctl is-active user@1000.service",
            timeout=datetime.timedelta(seconds=60),
        )
        machine.wait_until_succeeds(user_bus, timeout=datetime.timedelta(seconds=60))

    with subtest("a clean stop stays stopped"):
        machine.succeed("systemctl stop user@1000.service")
        machine.sleep(duration=datetime.timedelta(seconds=10))
        machine.fail("systemctl is-active user@1000.service")
  '';
}
