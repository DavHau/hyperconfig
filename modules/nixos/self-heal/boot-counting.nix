# Self-heal part 3: boot counting on the systemd-boot machines (amy joy nas
# som vit; docs/self-heal.md has the full walk-through). A generation that
# never boots healthy falls back to the last good boot entry on its own.
#
# systemd-boot's Automatic Boot Assessment, through nixpkgs'
# boot.loader.systemd-boot.bootCounting: every NEW entry file is written as
# nixos-<hash>+2.conf; systemd-boot renames it +1-1, +0-2 as it picks it
# (before the kernel loads) and sets LoaderBootCountPath; in stage 2
# systemd-bless-boot-generator (only on such a counted boot) pulls in
# systemd-bless-boot.service, which waits for boot-complete.target and then
# drops the counter (blessed = plain nixos-<hash>.conf). An entry at +0 is
# "bad": loader.conf's `preferred <profile entry>` skips it and
# `default nixos-*` picks the newest entry that is not bad.
#
# This file adds the health gate: selfheal-boot-healthy.service is
# RequiredBy + Before boot-complete.target, so a boot is only blessed once
# `selfheal health --level boot` passes (sshd listening; with
# bootHealth.requireGateway also a link up and any default route's gateway
# answering ICMP/ARP; never the internet, the mesh, tang or nas's data
# pools, so an upstream outage cannot mark a good generation bad). It
# retries for bootHealth.timeout; if the boot is still unhealthy it reboots,
# so systemd-boot spends the next try, but ONLY on a try-counted entry
# (LoaderBootCountPath + `systemd-bless-boot status` indeterminate/dirty),
# at most `tries` times per entry, never while `selfheal hold` or a switch
# runs, and on vit/som only while a Tang peer (bootHealth.tangPeers)
# answers (two-phase: own tangd.socket stopped first, peer checked again
# 15 s later; the peer is polled for up to 1 h), so the two never wait at
# their unlock for each other. A blessed
# or uncounted entry never reboots from here: no loop. A live switch to
# the system profile renames its bad (+0-N) entry back to +<tries>
# (selfheal.py retry_profile_entry, from the deploy guard's pre-switch
# check).
# Because the unit only exists in the transaction of a counted boot (the
# generator pulls boot-complete.target in), uncounted boots never run it.
#
# Stage 2 only: the unit is a normal system unit, so on vit (LUKS + tang)
# and som (ZFS + tang) it starts after the root is unlocked; the counter
# was already spent when systemd-boot picked the entry, so the unlock wait
# itself costs nothing, but every power-cycle while stuck at the unlock
# prompt costs one try.
{
  config,
  lib,
  ...
}:
let
  cfg = config.hyper.selfHeal;
  bcfg = cfg.bootCounting;
  hcfg = cfg.bootHealth;
  sdboot = config.boot.loader.systemd-boot.enable;
in
{
  options.hyper.selfHeal = {
    bootCounting = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable && sdboot;
        defaultText = lib.literalExpression "config.hyper.selfHeal.enable && config.boot.loader.systemd-boot.enable";
        description = "systemd-boot boot counting with the local health gate (selfheal-boot-healthy.service).";
      };
      tries = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Boots a new entry gets before systemd-boot falls back to the previous one.";
      };
    };

    bootHealth = {
      requireGateway = lib.mkOption {
        type = lib.types.bool;
        default = !cfg.roaming;
        defaultText = lib.literalExpression "!config.hyper.selfHeal.roaming";
        description = ''
          The boot gate also needs a link up and a default gateway answering.
          Off on roaming laptops: they boot offline on purpose, then sshd up
          is enough.
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = "Seconds the boot gate retries before the boot counts as failed.";
      };
      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Seconds between the boot gate's health checks.";
      };
      tangPollInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Seconds between peer checks while the restart waits only for a Tang peer.";
      };
      tangPollTimeout = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3600;
        description = "Seconds the gate keeps polling for a Tang peer before it gives up and stays up unblessed.";
      };
      tangWithdraw = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = "Seconds between stopping our own Tang and the second peer check (longer than a peer's check-to-restart latency).";
      };
      tangPeers = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              address = lib.mkOption {
                type = lib.types.str;
                example = "fe80::7a6e:1";
                description = "The peer's Tang address (its hyper.tangServer.address).";
              };
              dev = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "br0";
                description = "This machine's stage-2 LAN interface the link-local address is scoped to.";
              };
            };
          }
        );
        default = [ ];
        description = ''
          Tang servers that unlock this machine's root (vit and som unlock
          each other). Before restarting, the gate stops its own
          tangd.socket, waits `tangWithdraw` s and checks again, so two
          gates expiring together both stay up. The gate restarts the machine only while at least one
          answers on TCP 7654: otherwise both could end up waiting at their
          unlock for each other. Set where hyper.tangClient.servers is.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && bcfg.enable) {
    assertions = [
      {
        assertion = sdboot;
        message = "hyper.selfHeal.bootCounting needs boot.loader.systemd-boot (NixOS has no boot counting for GRUB or extlinux).";
      }
      {
        # mutual tang (vit <-> som): never restart without a peer to unlock us
        assertion = (config.hyper.tangClient.servers or [ ]) == [ ] || hcfg.tangPeers != [ ];
        message = "hyper.selfHeal.bootHealth.tangPeers must name the Tang peers of hyper.tangClient.servers (docs/self-heal.md, encrypted roots).";
      }
      {
        # the two-phase check withdraws our own Tang (tangd.socket) first
        assertion = hcfg.tangPeers == [ ] || (config.hyper.tangServer.enable or false);
        message = "hyper.selfHeal.bootHealth.tangPeers is meant for mutual Tang peers: this machine must run hyper.tangServer too.";
      }
    ];

    boot.loader.systemd-boot.bootCounting = {
      enable = true;
      inherit (bcfg) tries;
    };

    systemd.services.selfheal-boot-healthy = {
      description = "selfheal: local health gate of boot-complete.target (boot counting)";
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      after = [
        "network-online.target"
        "sshd.service"
        "sshd.socket"
        "selfheal-boot.service"
      ];
      # Only for the gateway: a laptop judged by sshd alone must not wait
      # for a network that is not there.
      wants = lib.optional hcfg.requireGateway "network-online.target";
      # A switch never re-runs the gate of a boot already assessed.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/selfheal boot-health";
        # gate + Tang peer polling + withdraw, plus slack
        TimeoutStartSec = hcfg.timeout + hcfg.tangPollTimeout + hcfg.tangWithdraw + 300;
      };
    };
  };
}
