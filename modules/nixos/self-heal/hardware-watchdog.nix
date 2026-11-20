# Self-heal part 2: the hardware watchdog (docs/self-heal.md). systemd
# (PID 1) pings /dev/watchdog from its main loop every RuntimeWatchdogSec/4
# to /2; if PID 1 or the kernel hangs for longer than RuntimeWatchdogSec,
# the board resets the machine. This catches full hangs only (a stuck
# kernel, a wedged PID 1), never "sshd stopped": that is the deploy
# guard's and the runtime watchdog's job.
#
# Where no watchdog device exists (sgp: no device; a VM without one) systemd
# logs that it can't open /dev/watchdog and carries on, so the setting is
# safe fleet-wide. Devices seen live (2026-11-20, read-only): bam and som
# SP5100 TCO, edi iTCO_wdt, cm-pi StarFive (max 357 s), vit iTCO; amy, joy
# and nas were offline, decided from their hardware configs (see the
# per-machine table in docs/self-heal.md).
#
# PID 1 can't ping while it re-execs or reloads (daemon-reload during a
# switch). On som (4600 units, ZFS root, high load) a switch spent 25 s in
# startup after the re-exec and 21 s in the reload (2026-11-19), so som
# runs 2 min (machines/som/self-heal.nix); elsewhere these steps take
# <= 3.3 s.
#
# RebootWatchdogSec=10min is systemd's default (already live); pinned here
# so it is explicit. It starts at systemd-shutdown, which pings per
# umount/detach round, so it only cuts a single call blocked for 10 min.
#
# Suspend: PID 1 is frozen, so nobody pings while asleep. iTCO stops its
# timer for s2idle (iTCO_wdt_suspend_noirq) and the firmware stops it for
# S3. Hibernation (iTCO keeps counting) is impossible fleet-wide: no swap
# device or resumeDevice. sp5100_tco has no suspend hooks, so an AMD laptop
# in s2idle could be reset by a counter nobody pings. amy (AMD FCH, s2idle
# only) therefore turns it off in machines/amy/configuration.nix until a
# suspend test on amy proves otherwise; joy (Intel, iTCO) and vit (never
# sleeps) keep it.
{
  config,
  lib,
  ...
}:
let
  cfg = config.hyper.selfHeal;
  wcfg = cfg.hardwareWatchdog;
in
{
  options.hyper.selfHeal.hardwareWatchdog = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.hyper.selfHeal.enable";
      description = "Let systemd drive the hardware watchdog (RuntimeWatchdogSec), where a device exists.";
    };
    runtime = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = "RuntimeWatchdogSec: a PID 1 or kernel hang longer than this resets the machine.";
    };
    reboot = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = "RebootWatchdogSec (systemd's default): a reboot or poweroff whose final stage hangs longer than this is forced.";
    };
  };

  config = lib.mkIf (cfg.enable && wcfg.enable) {
    systemd.settings.Manager = {
      RuntimeWatchdogSec = lib.mkDefault wcfg.runtime;
      RebootWatchdogSec = lib.mkDefault wcfg.reboot;
    };
  };
}
