{ pkgs, lib, ... }:
# Aggressively cap the CPU while the `power-saver` power-profiles-daemon
# profile is active, going well below what PPD does on its own.
#
# Background: on amd_pstate (active/EPP mode, e.g. the Framework AMD
# Ryzen AI 300 in `amy`), PPD's `power-saver` profile only biases the
# energy/performance preference to `power`. It does NOT lower the
# frequency ceiling and does NOT disable boost — so cores still burst to
# their boost clock (~3.1 GHz observed) under light load.
#
# Behaviour:
# - On `power-saver` profile → disable boost and cap every core's
#   `scaling_max_freq` at `capKHz` (1.2 GHz).
# - On any other profile     → restore boost and reset each core's
#   `scaling_max_freq` to its hardware `cpuinfo_max_freq`.
#
# Same watcher pattern as ./fw-fanctrl.nix: poll `powerprofilesctl get`
# and react on change. Polling (vs D-Bus signals) keeps it robust; the
# worst-case latency is one poll interval, which is fine for power.
let
  # Frequency cap applied on `power-saver`, in kHz. Valid range on amy is
  # ~605000 (cpuinfo_min) .. 2000000 (cpuinfo_max / nominal). 1.2 GHz is
  # a strong saving that is still usable for light desktop work.
  capKHz = 1200000;

  boostKnob = "/sys/devices/system/cpu/cpufreq/boost";

  watcher = pkgs.writeShellScript "cpu-powersave-cap-watcher" ''
    set -u
    PATH=${lib.makeBinPath [
      pkgs.power-profiles-daemon
      pkgs.coreutils
    ]}

    set_boost() {
      # Global amd_pstate boost toggle (1 = enabled, 0 = disabled).
      [ -w ${boostKnob} ] && echo "$1" > ${boostKnob} || true
    }

    set_max() {
      # $1 = "cap" -> ${toString capKHz} kHz; "restore" -> per-core hw max.
      for d in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -d "$d" ] || continue
        if [ "$1" = "cap" ]; then
          echo ${toString capKHz} > "$d/scaling_max_freq" 2>/dev/null || true
        else
          if [ -r "$d/cpuinfo_max_freq" ]; then
            cat "$d/cpuinfo_max_freq" > "$d/scaling_max_freq" 2>/dev/null || true
          fi
        fi
      done
    }

    apply() {
      case "$1" in
        power-saver)
          set_boost 0
          set_max cap
          ;;
        *)
          set_boost 1
          set_max restore
          ;;
      esac
    }

    last=""
    while true; do
      current=$(powerprofilesctl get 2>/dev/null || echo "")
      if [ -n "$current" ] && [ "$current" != "$last" ]; then
        apply "$current"
        last="$current"
      fi
      sleep 3
    done
  '';
in
{
  systemd.services.cpu-powersave-cap = {
    description = "Cap CPU freq + disable boost while power-saver profile is active";
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${watcher}";
      # ExecStop restores defaults so toggling the service off doesn't
      # leave the CPU pinned low.
      ExecStop = pkgs.writeShellScript "cpu-powersave-cap-restore" ''
        set -u
        [ -w ${boostKnob} ] && echo 1 > ${boostKnob} || true
        for d in /sys/devices/system/cpu/cpu*/cpufreq; do
          [ -r "$d/cpuinfo_max_freq" ] || continue
          ${pkgs.coreutils}/bin/cat "$d/cpuinfo_max_freq" > "$d/scaling_max_freq" 2>/dev/null || true
        done
      '';
    };
  };
}
