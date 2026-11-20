# Deploy guard: every live switch must prove the machine is still reachable,
# or it is rolled back and the machine reboots into the previous generation.
# Why: on 2026-11-19 a switch stopped sshd and every mesh daemon on nas and
# vit and never started them again; only a power-cycle got them back. clan
# (no rollback, issue #3078) and nixos-rebuild offer nothing here, so the
# switch arms its own dead man's timer (deploy-rs' "magic rollback" idea,
# without changing the deploy tool). Options under hyper.selfHeal.deployGuard,
# the CLI and health check in ./default.nix and ./selfheal.py, the operator
# guide in docs/self-heal.md, VM test ./test.nix (check self-heal-deploy-guard).
#
# 1. system.preSwitchChecks.self-heal-deploy-guard runs in the NEW system's
#    switch-to-configuration ($1 = new toplevel, $2 = action) before the
#    boot loader is installed. For `switch` to a system other than the
#    running one it records /run/current-system as `prev` (clan has already
#    pointed the profile at the new system, so the profile's previous
#    generation is not the running one) and arms a transient timer
#    (`systemd-run --on-active=<deadline>`). Transient units live in
#    /run/systemd/transient: switch-to-configuration only stops or restarts
#    units whose FragmentPath is under /etc/systemd/system, so the switch
#    can't take the timer down (nor does a daemon-reexec). Before arming it
#    records the deploy health as the baseline: only items healthy then are
#    judged later (a unit already dead can't be the switch's fault). The
#    check always exits 0 (any error is logged), except for the block in 4.
# 2. When the timer fires, `selfheal deploy-guard assess` judges deploy
#    health (`stableChecks` times in a row):
#    - healthy: confirmed, unless a switch still runs (clan-switch-*/
#      clan-boot-* unit or a switch-to-configuration process): then it
#      re-checks every `extendStep` until it finished or `maxExtend` passed.
#    - a hold (`selfheal hold <min>`) re-arms for its expiry, nothing else.
#    - only the anchors fail while sshd and the mesh daemons run and the
#      local link and gateway answer: an upstream outage, not this switch.
#      Re-check until `maxExtend`, then confirm (how=upstream); never
#      restore or roll back.
#    - otherwise restore at once, even while a switch still runs: start
#      multi-user.target, sshd and the mesh units (reset-failed first), and
#      re-check for `restoreWindow`. Still unhealthy: wait for a running
#      switch until `maxExtend`, then kill it,
#      `nix-env -p /nix/var/nix/profiles/system --set <prev>`,
#      `NIXOS_NO_CHECK=1 <prev>/bin/switch-to-configuration boot`, write the
#      rollback flag, reboot. If prev is gone or its boot step fails, it
#      reboots anyway (into the new generation's entry): a fresh boot beats
#      staying locked out.
# 3. A pending deploy survives a reboot (/var/lib/selfheal/deploy-guard/
#    pending.json): selfheal-boot.service re-arms it with a fresh deadline if
#    the new system booted, and drops it if another one did.
# 4. While the rollback flag exists the check FAILS for `switch` and `boot`
#    (clan runs `boot` first) with one line naming the rollback;
#    `selfheal clear` lifts it. NIXOS_NO_CHECK=1 skips every pre-switch
#    check: then nothing is armed and nothing is blocked.
# `selfheal confirm` (deploy-parallel.sh runs it after each deploy) disarms
# at once if healthy. Metrics: selfheal_deploy_guard_* in /run/selfheal
# (Alloy), alert "Deploy rolled back" in modules/nixos/monitoring-alerts.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.selfHeal;
  gcfg = cfg.deployGuard;
in
{
  options.hyper.selfHeal.deployGuard = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.hyper.selfHeal.enable";
      description = "Arm the deploy guard on every live switch.";
    };
    deadline = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15 * 60;
      description = "Seconds after the switch starts until the guard assesses health.";
    };
    maxExtend = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60 * 60;
      description = "Upper bound, in seconds after arming, for pushing the decision out: while a switch still runs (confirm and rollback wait for it), and for an upstream-only outage (then confirmed how=upstream).";
    };
    extendStep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5 * 60;
      description = "Seconds the assessment is pushed out per step (running switch, released hold).";
    };
    restoreWindow = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Seconds the guard waits for health after restarting the stopped units, before it rolls back.";
    };
    stableChecks = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Consecutive healthy checks (1 s apart) that count as healthy.";
    };
    extraRestoreUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Units started in the restore step besides multi-user.target, sshd and the mesh units.";
    };
  };

  config = lib.mkIf (cfg.enable && gcfg.enable) {
    # Exit 3 from the CLI = blocked by the rollback flag; anything else
    # (success, a crash, a hang past 2 min) lets the switch go on.
    system.preSwitchChecks.self-heal-deploy-guard = ''
      rc=0
      ${pkgs.coreutils}/bin/timeout 120 ${cfg.package}/bin/selfheal deploy-guard pre-switch "$1" "$2" || rc=$?
      if [ "$rc" -eq 3 ]; then
        exit 1
      fi
      if [ "$rc" -ne 0 ]; then
        echo "selfheal: deploy guard check failed ($rc), switching unguarded" >&2
      fi
      exit 0
    '';
  };
}
