{
  config,
  pkgs,
  lib,
  ...
}:
let
  greetdIdleRestartPath = [
    config.systemd.package
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnused
    pkgs.jq
  ];
  greetdIdleRestart = pkgs.writeShellScript "greetd-idle-restart" (
    builtins.readFile ./greetd-idle-restart.sh
  );
in
{
  # spaces' desktop profile now defaults to COSMIC + cosmic-greeter
  # (spaces.nix, mkDefault); that module also claims greetd's default
  # session. This host stays on tuigreet -> niri.
  services.displayManager.cosmic-greeter.enable = false;

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = lib.concatStringsSep " " [
          "${pkgs.tuigreet}/bin/tuigreet"
          "--time"
          "--remember"
          "--remember-user-session"
          "--asterisks"
          "--cmd niri-session"
        ];
        user = "greeter";
      };
    };
  };

  # NixOS enables lightdm by default once xserver.enable = true; force it off
  # so greetd is the sole display manager.
  services.xserver.displayManager.lightdm.enable = lib.mkForce false;

  # Don't tear down the active session on `nixos-rebuild switch`. greetd only
  # needs to be running to authenticate the next login; restarting it kicks
  # tuigreet's child PAM session, which kills the user's compositor.
  systemd.services.greetd = {
    restartIfChanged = false;
    # A greetd left running from an old generation dlopens the new PAM
    # modules against its old glibc ("GLIBC_2.43 not found"), every
    # login fails, and tuigreet retries in a tight loop (~80k lines per
    # 30 s on som, which rotated the whole journal away). Cap what one
    # broken greeter can write (journald's default is 10000 per 30 s).
    serviceConfig = {
      LogRateLimitIntervalSec = "30s";
      LogRateLimitBurst = 500;
    };
  };

  # The safe half of restartIfChanged: greetd-idle-restart.sh restarts
  # greetd only when the running process is definitely an old greetd
  # (its exe is a greetd binary at a different store path, or it runs
  # with another config) and seat0 is idle: a greeter session is on it
  # and no other session holds it, checked twice ~2 s apart (no greeter
  # = a login in progress = busy). So an idle greeter never runs stale
  # code and a live or starting compositor session is never killed.
  # It runs:
  # - on every switch that changes greetd.service (restartTriggers);
  # - whenever seat0's sessions change (path unit on logind's
  #   /run/systemd/seats/seat0, --quiet), plus every 10 min as a
  #   fallback (a logged-out session can linger "closing" with no
  #   further change). This covers the residual case: a user stays
  #   logged in through a glibc/PAM bump, then logs out; the stale
  #   greetd can't start the greeter (or any login) any more, and would
  #   otherwise stay broken until the next greetd-changing switch or a
  #   reboot. Now it is restarted right at logout.
  # Both are fail safe: on any doubt they do nothing, and they always
  # exit 0, so they can never fail a switch. At most one restart per
  # 10 min (/run stamp; the timer retries), so the restart itself can't
  # loop, and a stale greetd that loops anyway is capped by the rate
  # limit above. Live seat0 sessions are never touched: a user still
  # logged in keeps the stale greetd until they log out. If a restart
  # can't fix the mismatch, the timer restarts the idle greeter once per
  # 10 min (bounded, logged each time).
  # No start limit on either service (a logout + quick re-login rewrites
  # seat0 several times within 10 s; the default 5-in-10s limit would
  # fail the service and the path unit with it), and a short start
  # timeout so a hung D-Bus can't hold them for 90 s.
  systemd.services.greetd-idle-restart = {
    description = "Restart a stale greetd after a switch when seat0 is idle";
    wantedBy = [ "multi-user.target" ];
    # logind restarts in the same switch on som; order after it so
    # loginctl answers (a failure there is handled as "busy" anyway).
    after = [
      "greetd.service"
      "systemd-logind.service"
    ];
    restartTriggers = [ config.systemd.units."greetd.service".unit ];
    path = greetdIdleRestartPath;
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${greetdIdleRestart}";
      TimeoutStartSec = "30s";
    };
  };

  systemd.services.greetd-idle-restart-check = {
    description = "Restart a stale greetd once seat0 is idle";
    after = [
      "greetd.service"
      "systemd-logind.service"
    ];
    path = greetdIdleRestartPath;
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${greetdIdleRestart} --quiet";
      TimeoutStartSec = "30s";
      # Drop PID 1's info-level Starting/Finished lines (every seat0
      # change and every 10 min); the script's own lines, which are only
      # the decisions that matter in --quiet mode, go out at notice.
      LogLevelMax = "notice";
      SyslogLevel = "notice";
    };
  };

  systemd.paths.greetd-idle-restart-check = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "/run/systemd/seats/seat0";
  };

  systemd.timers.greetd-idle-restart-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "10min";
    };
  };
}
