{ pkgs, ... }:
# Workaround for amd-pstate-epp (active / EPP mode) failing to restore the
# upper CPU frequency cap after s2idle resume on AMD Ryzen AI 300
# (Strix Point) — the Framework 13 in `amy`.
#
# Symptom: after resume every core is pinned at `lowest_nonlinear_freq`
# (~0.6 GHz) and refuses to ramp regardless of governor, EPP, core boost,
# power source or temperature. The CPPC handoff between the OS and the SMU
# firmware does not re-negotiate the perf caps on resume, so the driver's
# cached max perf stays clamped. Writing `scaling_max_freq` directly is
# ignored by the driver in this state; only a full driver reinit clears it.
#
# Fix: cycle the driver through `passive` -> `active`, which forces a
# complete reinitialization that re-reads the hardware perf limits.
# power-profiles-daemon is then restarted so it re-asserts the active
# profile's governor / EPP / boost on top of the freshly reinitialized
# driver (PPD only writes those on profile change or startup).
#
# A oneshot service `wantedBy` + `after` the sleep targets runs on resume,
# mirroring ./bluetooth-resume-fix.nix. Guards make it a no-op on any host
# that is not running amd-pstate in active mode.
#
# Refs:
#   https://community.frame.work/t/amd-cpu-stuck-in-low-speed-state-after-system-resume/39921
#   https://github.com/FrameworkComputer/SoftwareFirmwareIssueTracker/issues/91
{
  systemd.services.amd-pstate-resume-fix = {
    description = "Reinitialize amd-pstate after resume (Strix Point freq-cap workaround)";
    wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "amd-pstate-resume-fix" ''
        set -u
        status=/sys/devices/system/cpu/amd_pstate/status
        # Only act when amd-pstate is in active (EPP) mode; otherwise no-op.
        [ -w "$status" ] || exit 0
        [ "$(${pkgs.coreutils}/bin/cat "$status")" = "active" ] || exit 0

        echo passive > "$status" || exit 0
        ${pkgs.coreutils}/bin/sleep 1
        echo active > "$status" || exit 0

        # Re-assert governor / EPP / boost for the current profile on top of
        # the reinitialized driver. try-restart is a no-op if PPD is absent.
        ${pkgs.systemd}/bin/systemctl try-restart power-profiles-daemon.service || true
      '';
    };
  };
}
