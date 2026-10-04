{ config, pkgs, lib, ... }:
# Run maintenance chores (store GC/optimise, backups, ZFS scrub/trim, fstrim,
# firmware metadata refresh) only while the laptop is on AC power AND
# power-profiles-daemon is not in `power-saver`.
#
# Mechanism: a watcher starts `chores-allowed.target` when both hold and
# stops it otherwise. The chore timers are wanted by and PartOf that target
# instead of timers.target, and all carry Persistent=true:
#
# - Disallowed -> timers are stopped, so nothing fires.
# - Allowed again -> timers start, and Persistent catches up every run whose
#   elapse passed meanwhile. Chores are deferred, never dropped. (An
#   ExecCondition gate would drop them: systemd records a skipped run as
#   triggered and waits for the next calendar slot.)
# - The chore services are PartOf the target too, so unplugging or switching
#   to power-saver stops a running chore. borg resumes from its checkpoints;
#   GC/optimise/trim are idempotent.
#
# ZFS scrub and trim run inside the kernel, detached from their service
# (`zpool trim` returns at once; killing `zpool scrub -w` leaves the scrub
# running). zfs-chores-gate therefore pauses running scrubs / suspends
# running trims when the target stops and resumes them when it starts again,
# so an interrupted monthly scrub continues on the next AC session instead
# of waiting a month.
#
# Catch-up after a long battery stretch would start everything at once on
# plug-in; a uniform 15 min RandomizedDelaySec spreads them out.
#
# User-level chores get the same treatment through a user target that
# mirrors the system one.
let
  systemChores = [
    "nix-optimise"
    "fast-nix-gc"
    "borgbackup-job-nas"
    "zfs-scrub"
    "zpool-trim"
    "fstrim"
    "fwupd-refresh"
  ];
  userChores = [
    "cargo-build-gc"
    "sbox-gc"
  ];

  gatedTimer = {
    wantedBy = lib.mkForce [ "chores-allowed.target" ];
    partOf = [ "chores-allowed.target" ];
    timerConfig = {
      Persistent = true;
      RandomizedDelaySec = lib.mkForce "15min";
    };
  };
  gatedService.partOf = [ "chores-allowed.target" ];

  forAll = names: value: lib.genAttrs names (_: value);

  zpool = "${config.boot.zfs.package}/bin/zpool";

  watcher = pkgs.writeShellScript "chores-on-ac-watcher" ''
    set -u
    PATH=${lib.makeBinPath [
      pkgs.systemd
      pkgs.coreutils
    ]}

    on_ac() {
      for ps in /sys/class/power_supply/*; do
        [ "$(cat "$ps/type" 2>/dev/null)" = Mains ] || continue
        [ "$(cat "$ps/online" 2>/dev/null)" = 1 ] && return 0
      done
      return 1
    }

    last=""
    while true; do
      profile=$(busctl get-property org.freedesktop.UPower.PowerProfiles \
        /org/freedesktop/UPower/PowerProfiles \
        org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null || echo "")
      # Unknown profile (PPD down) counts as disallowed.
      if on_ac && [ -n "$profile" ] && [ "$profile" != 's "power-saver"' ]; then
        want=start
      else
        want=stop
      fi
      if [ "$want" != "$last" ]; then
        systemctl --no-block "$want" chores-allowed.target
        last="$want"
      fi
      sleep 3
    done
  '';

  # `zpool status -t` lines matched below:
  #   scan: scrub in progress since … / scan: scrub paused since …
  #   (12% trimmed, started at …)    / (12% trimmed, suspended, started at …)
  zfsGateActions = {
    resume = ''
      case "$status" in *"scan: scrub paused"*) ${zpool} scrub "$pool" || true ;; esac
      case "$status" in *"trimmed, suspended"*) ${zpool} trim "$pool" || true ;; esac
    '';
    pause = ''
      case "$status" in *"scan: scrub in progress"*) ${zpool} scrub -p "$pool" || true ;; esac
      case "$status" in *"trimmed, started"*) ${zpool} trim -s "$pool" || true ;; esac
    '';
  };
  zfsGate = action: pkgs.writeShellScript "zfs-chores-${action}" ''
    set -u
    for pool in $(${zpool} list -H -o name); do
      status=$(${zpool} status -t "$pool")
      ${zfsGateActions.${action}}
    done
  '';

  userWatcher = pkgs.writeShellScript "chores-on-ac-user-watcher" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.systemd pkgs.coreutils ]}
    last=""
    while true; do
      if systemctl --system is-active --quiet chores-allowed.target; then
        want=start
      else
        want=stop
      fi
      if [ "$want" != "$last" ]; then
        systemctl --user --no-block "$want" chores-allowed.target
        last="$want"
      fi
      sleep 3
    done
  '';
in
{
  systemd.targets.chores-allowed.description = "Maintenance chores allowed (AC power, not power-saver)";

  systemd.timers = forAll systemChores gatedTimer // {
    # Upstream fwupd unit refreshes hourly. OnCalendar accumulates across
    # drop-ins, so reset it before setting the new value.
    fwupd-refresh = gatedTimer // {
      timerConfig = gatedTimer.timerConfig // { OnCalendar = [ "" "weekly" ]; };
    };
  };

  systemd.services = forAll systemChores gatedService // {
    chores-on-ac = {
      description = "Start chores-allowed.target on AC power outside power-saver";
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

    zfs-chores-gate = {
      description = "Resume ZFS scrub/trim with chores-allowed.target, pause them without it";
      after = [ "zfs-import.target" ];
      wantedBy = [ "chores-allowed.target" ];
      partOf = [ "chores-allowed.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${zfsGate "resume"}";
        ExecStop = "${zfsGate "pause"}";
      };
    };
  };

  systemd.user.targets.chores-allowed.description = "Maintenance chores allowed (mirrors the system target)";
  systemd.user.timers = forAll userChores gatedTimer;
  systemd.user.services = forAll userChores gatedService // {
    chores-on-ac = {
      description = "Mirror system chores-allowed.target into the user manager";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${userWatcher}";
      };
    };
  };
}
