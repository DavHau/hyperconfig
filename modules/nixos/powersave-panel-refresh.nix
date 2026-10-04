{ config, pkgs, lib, ... }:
# Drop the built-in laptop panel (eDP-*) to its lowest refresh rate at the
# current resolution while power-profiles-daemon is in `power-saver`, and
# back to the highest when leaving it.
#
# On `amy` the 2880x1920 panel runs at 120 Hz with panel self refresh
# disabled (amdgpu.dcdebugmask=0x10), so every frame is scanned out even on
# a static desktop; 60 Hz halves that display-engine and panel work.
#
# niri runtime output changes are transient: a config reload or monitor
# hotplug reverts the panel to its configured mode. So while in power-saver
# the watcher re-asserts the low mode whenever it drifts; outside
# power-saver it only acts once on the transition and otherwise leaves the
# mode alone. The change never reaches ~/.config/niri/displays.kdl unless
# save-niri-displays runs (wdisplays closed) while in power-saver.
let
  watcher = pkgs.writeShellScript "powersave-panel-refresh-watcher" ''
    set -u
    PATH=${lib.makeBinPath [
      pkgs.systemd
      pkgs.coreutils
      pkgs.jq
      config.programs.niri.package
    ]}

    # $1 = "low" | "high". Emits "<output> <WxH@Hz>" for every lit eDP
    # output whose current mode differs from the wanted one.
    wanted_modes() {
      niri msg --json outputs 2>/dev/null | jq -r --arg want "$1" '
        to_entries[]
        | select(.key | startswith("eDP"))
        | select(.value.current_mode != null)
        | .key as $name
        | .value.modes as $modes
        | $modes[.value.current_mode] as $cur
        | [ $modes[] | select(.width == $cur.width and .height == $cur.height) ]
        | (if $want == "low" then min_by(.refresh_rate) else max_by(.refresh_rate) end) as $m
        | select($m.refresh_rate != $cur.refresh_rate)
        | "\($name) \($m.width)x\($m.height)@\($m.refresh_rate / 1000)"
      '
    }

    set_modes() {
      wanted_modes "$1" | while read -r name mode; do
        niri msg output "$name" mode "$mode" || true
      done
    }

    last=""
    while true; do
      # Output: s "power-saver"
      current=$(busctl get-property org.freedesktop.UPower.PowerProfiles \
        /org/freedesktop/UPower/PowerProfiles \
        org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null || echo "")
      current=''${current#s \"}
      current=''${current%\"}
      if [ -n "$current" ]; then
        if [ "$current" = power-saver ]; then
          set_modes low
        elif [ "$last" = power-saver ]; then
          set_modes high
        fi
        last="$current"
      fi
      sleep 3
    done
  '';
in
{
  systemd.user.services.powersave-panel-refresh = {
    description = "Lower laptop panel refresh rate while power-saver profile is active";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${watcher}";
      Restart = "always";
      RestartSec = 5;
    };
  };
}
