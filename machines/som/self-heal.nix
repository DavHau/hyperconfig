# som's self-heal settings (docs/self-heal.md).
{
  # PID 1 can't ping the hardware watchdog while it re-execs or reloads; on
  # som (4600 units, ZFS root, high load) a switch on 2026-11-19 spent 25 s
  # in startup after the re-exec and 21 s in the reload. 30 s would reset
  # som mid-deploy (modules/nixos/self-heal/hardware-watchdog.nix).
  hyper.selfHeal.hardwareWatchdog.runtime = "2min";
}
