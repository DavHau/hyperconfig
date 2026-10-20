# Bring a user's `systemd --user` manager back after it dies.
#
# Upstream user@.service has no Restart=, and logind starts a lingering
# user's manager only at boot, on login or on `enable-linger`. When the
# manager is killed (som, 2026-10-19: a global OOM picked the managers,
# which run at oom_score_adj 100), it stays dead: every lingering user
# service of that user is down, and user-runtime-dir@ keeps
# /run/user/<uid> with a stale bus socket, so each switch-to-configuration
# fails "reloading user units" with "Connection refused" on that bus.
#
# Restart=on-failure only covers a manager that crashes or is killed; a
# clean stop (logout of a non-lingering user, disable-linger) stays
# stopped. The backoff keeps a manager that is killed over and over during
# a long memory squeeze from spinning.
#
# Tested by the `user-manager-restart` flake check (./test.nix).
{
  systemd.services."user@".serviceConfig = {
    Restart = "on-failure";
    RestartSec = "5s";
    RestartSteps = 5;
    RestartMaxDelaySec = "5min";
  };
}
