{ pkgs, lib, ... }:
# Declarative Framework laptop fan curve via fw-fanctrl, gated on the
# active power-profiles-daemon profile.
#
# Behaviour:
# - On `performance` profile  → fw-fanctrl runs the aggressive curve.
# - On any other profile      → service is stopped; ExecStopPost runs
#   `ectool autofanctrl`, returning the fan to the EC's stock curve.
#
# Rationale: the aggressive curve is intentionally noisy. We only want
# that trade-off when the user has explicitly opted into more thermal
# headroom by selecting `performance`.
#
# A small watcher service polls `powerprofilesctl` (D-Bus) every few
# seconds and toggles `fw-fanctrl.service` accordingly. Polling is used
# instead of D-Bus signal subscription for robustness — the worst-case
# latency between profile switch and fan-curve change is bounded by the
# poll interval, which is fine for thermal control.
let
  watcher = pkgs.writeShellScript "fw-fanctrl-profile-watcher" ''
    set -u
    PATH=${lib.makeBinPath [
      pkgs.systemd
      pkgs.power-profiles-daemon
      pkgs.coreutils
    ]}

    apply() {
      case "$1" in
        performance)
          systemctl is-active --quiet fw-fanctrl.service \
            || systemctl start fw-fanctrl.service
          ;;
        *)
          systemctl is-active --quiet fw-fanctrl.service \
            && systemctl stop fw-fanctrl.service
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
  hardware.fw-fanctrl = {
    enable = true;

    config = {
      defaultStrategy = "aggressive";

      strategies.aggressive = {
        fanSpeedUpdateFrequency = 2;
        movingAverageInterval = 6;
        speedCurve = [
          { temp = 0;   speed = 15; }
          { temp = 50;  speed = 20; }
          { temp = 65;  speed = 30; }
          { temp = 75;  speed = 40; }
          { temp = 85;  speed = 55; }
          { temp = 90;  speed = 75; }
          { temp = 95;  speed = 100; }
        ];
      };
    };
  };

  # Prevent fw-fanctrl from auto-starting at boot — the watcher decides
  # when it should run based on the active power profile.
  systemd.services.fw-fanctrl.wantedBy = lib.mkForce [ ];

  systemd.services.fw-fanctrl-profile-watcher = {
    description = "Gate fw-fanctrl on power-profiles-daemon `performance` profile";
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${watcher}";
    };
  };
}
