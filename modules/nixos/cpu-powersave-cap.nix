{ pkgs, lib, ... }:
# Apply an extra CPU frequency ceiling on top of power-profiles-daemon's
# `power-saver` profile, going below what PPD does on its own.
#
# Background: on amd_pstate active/EPP mode (the Framework AMD Ryzen AI 300
# in `amy`), PPD's `power-saver` profile already does a lot: it selects the
# `powersave` governor, biases EPP to `power`, lowers `scaling_min_freq` to
# `cpuinfo_min_freq`, and DISABLES core boost (CPB) per policy. With boost
# off the ceiling drops to the nominal `cpuinfo_max_freq` (~2.0 GHz on amy).
# This module shaves the ceiling further to `capKHz` (1.2 GHz) for stronger
# savings during light desktop work.
#
# IMPORTANT — never touch the boost knob here. PPD activates *every* profile
# by writing each per-policy `cpufreq/policyN/boost` file. If the *global*
# `/sys/devices/system/cpu/cpufreq/boost` is disabled, those per-policy
# writes fail with EINVAL and PPD aborts the whole driver activation:
#
#   Failed to activate CPU driver 'amd_pstate': Error writing
#   '/sys/devices/system/cpu/cpufreq/policy11/boost': Invalid argument (13)
#
# That rejects the profile switch, so the machine gets wedged in power-saver
# and the cap never lifts. Boost is PPD's job; this module only ever moves
# `scaling_max_freq`, which never blocks PPD.
#
# Watcher pattern mirrors ./fw-fanctrl.nix: poll `powerprofilesctl get` and
# react on change. On `power-saver` -> cap; on anything else -> lift the cap
# back to each core's hardware `cpuinfo_max_freq`. By the time we observe a
# non-power-saver profile, PPD has already re-enabled boost, so
# `cpuinfo_max_freq` reads the full boost ceiling and the lift is complete.
let
  # Frequency cap applied on `power-saver`, in kHz. Valid range on amy is
  # ~605000 (cpuinfo_min) .. 2000000 (nominal cpuinfo_max with boost off).
  # 1.2 GHz is a strong saving that is still usable for light desktop work.
  capKHz = 1200000;

  set_max = pkgs.writeShellScript "cpu-powersave-cap-set-max" ''
    set -u
    # $1 = "cap" -> ${toString capKHz} kHz; "restore" -> per-core hw max.
    for d in /sys/devices/system/cpu/cpu*/cpufreq; do
      [ -d "$d" ] || continue
      if [ "$1" = "cap" ]; then
        echo ${toString capKHz} > "$d/scaling_max_freq" 2>/dev/null || true
      elif [ -r "$d/cpuinfo_max_freq" ]; then
        ${pkgs.coreutils}/bin/cat "$d/cpuinfo_max_freq" > "$d/scaling_max_freq" 2>/dev/null || true
      fi
    done
  '';

  watcher = pkgs.writeShellScript "cpu-powersave-cap-watcher" ''
    set -u
    PATH=${lib.makeBinPath [
      pkgs.power-profiles-daemon
      pkgs.coreutils
    ]}

    last=""
    while true; do
      current=$(powerprofilesctl get 2>/dev/null || echo "")
      if [ -n "$current" ] && [ "$current" != "$last" ]; then
        case "$current" in
          power-saver) ${set_max} cap ;;
          *)           ${set_max} restore ;;
        esac
        last="$current"
      fi
      sleep 3
    done
  '';
in
{
  systemd.services.cpu-powersave-cap = {
    description = "Cap CPU scaling_max_freq while power-saver profile is active";
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${watcher}";
      # Stopping the service lifts our cap so toggling it off doesn't leave
      # the CPU pinned low. Boost is left untouched (PPD owns it).
      ExecStop = "${set_max} restore";
    };
  };
}
