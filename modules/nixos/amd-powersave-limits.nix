{ pkgs, lib, ... }:
# Tighter SoC power limits and GPU/panel savings while power-profiles-daemon
# is in `power-saver`, for the Framework 13 AMD Ryzen AI 300 (Strix Point)
# in `amy`.
#
# What PPD's power-saver does on its own: amd_pstate EPP `power`, boost off
# (see ./cpu-powersave-cap.nix), and ACPI platform_profile `low-power`, which
# makes amd-pmf hand the firmware's low-power slider limits to the SMU.
# Those firmware limits still let the package pull well over 20 W under
# load. This module adds:
#
# 1. SoC package limits via ryzenadj (STAPM / sustained / boost PPT). The
#    SMU enforces them across CPU + iGPU + NPU together, so this is the
#    knob that actually bounds wall power. amd-pmf re-sends its own limits
#    on profile change (so leaving power-saver restores the firmware
#    values without help from us) and may also re-send them on power
#    source / policy events, so the watcher re-asserts every 15 s while in
#    power-saver.
#
# 2. PPD's built-in amdgpu actions, which ship disabled:
#    - amdgpu_dpm: power_dpm_force_performance_level=low in power-saver
#      (iGPU pinned to its lowest sclk), auto otherwise.
#    - amdgpu_panel_power: ABM panel power savings in power-saver on
#      battery. Trades some colour accuracy for backlight power.
#    PPD persists these in /var/lib/power-profiles-daemon/state.ini; the
#    oneshot below makes them declarative.
let
  # SoC limits in mW applied on power-saver. With ~4-6 W for panel, RAM,
  # SSD and Wi-Fi this keeps sustained wall power around 16-18 W.
  stapmMilliwatts = 12000; # STAPM (skin-temperature-aware sustained) limit
  slowMilliwatts = 12000; # slow PPT (sustained package power)
  fastMilliwatts = 15000; # fast PPT (short boost bursts)

  apply_limits = pkgs.writeShellScript "amd-powersave-limits-apply" ''
    exec ${lib.getExe pkgs.ryzenadj} \
      --stapm-limit=${toString stapmMilliwatts} \
      --slow-limit=${toString slowMilliwatts} \
      --fast-limit=${toString fastMilliwatts} >/dev/null
  '';

  watcher = pkgs.writeShellScript "amd-powersave-limits-watcher" ''
    set -u
    PATH=${lib.makeBinPath [
      pkgs.systemd
      pkgs.coreutils
    ]}

    tick=0
    while true; do
      # Output: s "power-saver"
      current=$(busctl get-property org.freedesktop.UPower.PowerProfiles \
        /org/freedesktop/UPower/PowerProfiles \
        org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null || echo "")
      if [ "$current" = 's "power-saver"' ]; then
        # Apply on entry (tick reset below), then every 5th poll (15 s).
        if [ "$tick" -eq 0 ]; then
          ${apply_limits} || echo "ryzenadj failed" >&2
        fi
        tick=$(( (tick + 1) % 5 ))
      else
        tick=0
      fi
      sleep 3
    done
  '';
in
{
  systemd.services.amd-powersave-limits = {
    description = "Lower SoC power limits while power-saver profile is active";
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    # PPD >= 0.30 is After=multi-user.target; multi-user.target here would
    # be an ordering cycle (see ./cpu-powersave-cap.nix).
    wantedBy = [ "graphical.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${watcher}";
    };
  };

  systemd.services.power-profiles-daemon-amdgpu-actions = {
    description = "Enable power-profiles-daemon amdgpu actions";
    after = [ "power-profiles-daemon.service" ];
    requires = [ "power-profiles-daemon.service" ];
    wantedBy = [ "power-profiles-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${pkgs.power-profiles-daemon}/bin/powerprofilesctl configure-action amdgpu_dpm --enable"
        "${pkgs.power-profiles-daemon}/bin/powerprofilesctl configure-action amdgpu_panel_power --enable"
      ];
    };
  };
}
