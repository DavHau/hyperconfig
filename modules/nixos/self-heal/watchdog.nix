# Self-heal part 4: the runtime watchdog (docs/self-heal.md). Every minute
# `selfheal watchdog tick` (./selfheal.py, section "runtime watchdog")
# probes this machine's own services (sshd, mesh daemons), its default
# gateway (else a LAN neighbour), the internet probes and the overlay
# anchors with the same checks as `selfheal health`, classifies the result
# and escalates (repairs after 2 bad ticks in a row, never while a switch
# runs or `selfheal hold` is on):
#   sshd / a mesh daemon down -> reset-failed + start them, multi-user.target
#   overlays down      -> restart the mesh daemons (internet up)
#   gateway and LAN silent 5m -> restart the uplink (NetworkManager /
#                         wpa_supplicant / networkd; vit also reloads its
#                         Wi-Fi driver with ../initrd-wifi.nix's reloadDriver)
#   unreachable 30 min -> reboot, or roll an unconfirmed live switch back
#                         (the deploy guard's rollback), if every gate passes.
#                         Unreachable = sshd down, or no overlay anchor
#                         answers (the mesh state only after 2 h and two
#                         mesh restarts). A dead mesh daemon while an anchor
#                         answers is "degraded": repaired, never a reboot.
#   upstream outage    -> nothing, ever (gateway or a LAN neighbour
#                         answers, internet and anchors don't): log + metric
# Gates: 30 min after boot, 1 watchdog reboot per 24 h, no running switch,
# no `selfheal hold`, the tang peer (vit <-> som: intent published first,
# never while the peer just booted or reboots, the lower name first when
# both want to; a DOWN peer is overridden after peerOverrideHours, vit 1 h
# later than som), and on machines with a seat a 5 min warning a person at
# the seat can cancel once (`selfheal cancel`, or the notification's
# Cancel action).
# Modes: report (roaming laptops: probes and metrics only), repair (restart
# steps, no reboot), full. VM test: ./watchdog-test.nix.
{
  config,
  lib,
  options,
  pkgs,
  ...
}@args:
let
  cfg = config.hyper.selfHeal;
  wcfg = cfg.watchdog;
  me = config.networking.hostName;
  clanDir = config.clan.core.settings.directory or null;
  hasClanVars = options ? clan && options.clan ? core && options.clan.core ? vars;
  fleet = (args.self or { }).nixosConfigurations or { };

  tangServer = config.hyper.tangServer or { enable = false; };
  tangServers = config.hyper.tangClient.servers or [ ];
  # Mutual tang: we serve the peer and the peer serves us.
  derivedPeer =
    if tangServer.enable && tangServers != [ ] then lib.head tangServers else null;

  peerCfg = if wcfg.tangPeer != null && fleet ? ${wcfg.tangPeer} then fleet.${wcfg.tangPeer}.config else null;
  peerAddressesDefault = lib.optionals (wcfg.tangPeer != null) (
    # The peer's fixed link-local tang address on our LAN interface: works
    # without the internet and without any overlay.
    lib.optional (
      peerCfg != null && (peerCfg.hyper.tangServer.enable or false) && tangServer.enable
    ) "${peerCfg.hyper.tangServer.address}%${tangServer.interface}"
    ++ [ "${wcfg.tangPeer}.d" ]
  );

  readVar =
    rel:
    let
      f = "${clanDir}/vars/${rel}/value";
    in
    if clanDir != null && builtins.pathExists f then lib.trim (builtins.readFile f) else null;

  peerGen = "selfheal-peer-ssh";
  peerPub = readVar "shared/${peerGen}/key.pub";

  nm = config.networking.networkmanager.enable;
  uplinkUnitsDefault =
    lib.optional nm "NetworkManager.service"
    ++ lib.optional (!nm && config.networking.wireless.enable) "wpa_supplicant.service"
    ++ lib.optional config.systemd.network.enable "systemd-networkd.service";

  initrdWifi = config.hyper.initrdWifi or { enable = false; };

  peerActive = wcfg.tangPeer != null;

  # Where the peer connects from: its tang link-local (fe80::/10 on the
  # LAN) and its yggdrasil address (`<peer>.d`).
  peerYgg = if peerActive then readVar "per-machine/${wcfg.tangPeer}/yggdrasil/address" else null;
in
{
  options.hyper.selfHeal.watchdog = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.hyper.selfHeal.enable";
      description = "Run the runtime watchdog timer (selfheal-net-watchdog).";
    };
    mode = lib.mkOption {
      type = lib.types.enum [
        "report"
        "repair"
        "full"
      ];
      default = if cfg.roaming then "report" else "full";
      defaultText = lib.literalExpression ''if config.hyper.selfHeal.roaming then "report" else "full"'';
      description = ''
        report: probes and metrics only (laptops). repair: restart steps, no
        reboot. full: restart steps, then reboot when cut off (Dave: an
        unreachable machine must reboot).
      '';
    };
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds between ticks.";
    };
    switchHungAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = cfg.deployGuard.maxExtend;
      defaultText = lib.literalExpression "config.hyper.selfHeal.deployGuard.maxExtend (1 h)";
      description = ''
        A clan-switch-*/switch-to-configuration running longer than this
        (s) counts as hung: it no longer holds repairs or the reboot
        (event switch-hung). A switch with the deploy guard disarmed
        (NIXOS_NO_CHECK, by hand) is otherwise never killed.
      '';
    };
    repairAfterTicks = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "A fault must be seen on this many ticks in a row before the first repair (a deploy's stop window is shorter).";
    };
    meshRebootAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2 * 60 * 60;
      description = ''
        The mesh state (internet up, overlays down) counts towards the
        reboot only after this many seconds (+ per-host jitter) and two mesh
        restarts: an anchor-side overlay outage must not reboot the fleet.
      '';
    };
    meshRebootJitter = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30 * 60;
      description = "Up to this many seconds added to meshRebootAfter, fixed per host.";
    };
    lanPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.filter (a: lib.hasPrefix "fe80:" a) wcfg.peerAddresses;
      defaultText = lib.literalMD "the tang peer's link-local address";
      description = ''
        LAN addresses that, when the gateway is silent, show the LAN is up
        (the router is dead: upstream, not our link), besides an ff02::1
        all-nodes ping on the default route's interface.
      '';
    };
    linkGrace = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5 * 60;
      description = "Seconds the gateway stays silent before the uplink is restarted.";
    };
    repairInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10 * 60;
      description = "Each repair step (restore, mesh restart, uplink restart) runs at most this often (s).";
    };
    rebootAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30 * 60;
      description = "Seconds cut off (services, link or mesh state) before the reboot.";
    };
    bootGrace = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30 * 60;
      description = "No watchdog reboot within this many seconds after boot.";
    };
    rebootCap = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24 * 60 * 60;
      description = "At most one watchdog reboot per this many seconds (stamp in /var/lib/selfheal/watchdog).";
    };
    rollbackWindow = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24 * 60 * 60;
      description = "A live switch younger than this (s) and never confirmed is rolled back instead of a plain reboot.";
    };
    uplinkUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = uplinkUnitsDefault;
      defaultText = lib.literalMD "NetworkManager, else wpa_supplicant where wireless is on; systemd-networkd where enabled";
      description = "Units restarted when the gateway stays silent for linkGrace.";
    };
    uplinkReload = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if initrdWifi.enable then initrdWifi.reloadDriver else null;
      defaultText = lib.literalMD "../initrd-wifi.nix's reloadDriver where hyper.initrdWifi is on (vit)";
      description = "Script run before the uplink units restart (a driver reload).";
    };
    tangPeer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = derivedPeer;
      defaultText = lib.literalMD "the first of hyper.tangClient.servers where this machine runs a tang server too (vit: som, som: vit)";
      description = "Machine that holds our tang key while we hold its: never reboot both in the same window.";
    };
    peerRecentMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Refuse to reboot while the peer booted less than this long ago.";
    };
    peerOverrideHours = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 6;
      description = "Reboot regardless of the peer once cut off this long (an unknown peer counts as down).";
    };
    peerStaggerMinutes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 60;
      description = ''
        With the peer down, the machine later in name order (vit, before
        som) waits this much longer past peerOverrideHours, so both never
        override together. Must exceed peerRecentMinutes plus a boot.
      '';
    };
    peerFrom = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # sshd matches a link-local client WITH its %scope: a CIDR
      # (fe80::/10) never matches, a wildcard does (OpenSSH 10.6p1,
      # checked; review-part4b L3).
      default =
        lib.optional tangServer.enable "fe80::*%${tangServer.interface}"
        ++ lib.optional (peerYgg != null) peerYgg;
      defaultText = lib.literalMD "`fe80::*%<our tang interface>` and the peer's yggdrasil address";
      description = "`from=` of the peer key's authorized_keys line.";
    };
    peerAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = peerAddressesDefault;
      defaultText = lib.literalMD "the peer's tang link-local address on our LAN interface, then `<peer>.d`";
      description = "Where the peer's sshd is asked for its boot time, in order.";
    };
    peerPort = lib.mkOption {
      type = lib.types.port;
      default = lib.head (
        (if peerCfg != null then peerCfg.services.openssh.ports else config.services.openssh.ports) ++ [ 22 ]
      );
      defaultText = lib.literalMD "the peer's first services.openssh.ports";
      description = "The peer's sshd port.";
    };
    peerKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if peerActive && hasClanVars then config.clan.core.vars.generators.${peerGen}.files.key.path else null;
      defaultText = lib.literalMD "the `selfheal-peer-ssh` clan var";
      description = "Private key for the peer's forced command (peer-info).";
    };
    peerPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if peerActive then peerPub else null;
      defaultText = lib.literalMD "vars/shared/selfheal-peer-ssh/key.pub";
      description = "Authorized for root with a forced `selfheal watchdog peer-info` (restrict).";
    };
    peerHostKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if peerActive then readVar "per-machine/${wcfg.tangPeer}/openssh/ssh.id_ed25519.pub" else null;
      defaultText = lib.literalMD "the peer's clan openssh host key";
      description = "The peer's host key; null = not checked (tests only).";
    };
    seatWarning = lib.mkOption {
      type = lib.types.bool;
      default = wcfg.mode == "full" && (config.services.greetd.enable || config.services.displayManager.enable);
      defaultText = lib.literalMD "full mode on machines with a display manager (vit, som)";
      description = "Warn a person at seat0 before the reboot; they may cancel once per incident.";
    };
    countdown = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5 * 60;
      description = "Seconds between the seat warning and the reboot.";
    };
    testRebootCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      internal = true;
      default = null;
      description = "Tests only: run instead of the reboot (to tick two peers at once).";
    };
    testClockFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      internal = true;
      default = null;
      description = "Tests only: a file holding seconds added to the watchdog's clocks.";
    };
    rearmAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30 * 60;
      description = "After a cancel, warn again (uncancellable) this many seconds later if still cut off.";
    };
  };

  config = lib.mkIf (cfg.enable && wcfg.enable) (
    lib.mkMerge [
      {
        hyper.selfHeal.extraCliConfig.watchdog = {
          inherit (wcfg)
            mode
            interval
            switchHungAfter
            repairAfterTicks
            meshRebootAfter
            meshRebootJitter
            lanPeers
            testRebootCommand
            linkGrace
            repairInterval
            rebootAfter
            bootGrace
            rebootCap
            rollbackWindow
            uplinkUnits
            tangPeer
            peerAddresses
            peerPort
            peerKeyFile
            peerHostKey
            seatWarning
            countdown
            rearmAfter
            testClockFile
            ;
          uplinkReload = if wcfg.uplinkReload == null then null else "${wcfg.uplinkReload}";
          peerRecent = wcfg.peerRecentMinutes * 60;
          peerOverride = builtins.floor (wcfg.peerOverrideHours * 3600);
          peerStagger = wcfg.peerStaggerMinutes * 60;
        };
        assertions = [
          {
            assertion = wcfg.tangPeer == null || wcfg.peerStaggerMinutes > wcfg.peerRecentMinutes + 10;
            message = "hyper.selfHeal.watchdog.peerStaggerMinutes must exceed peerRecentMinutes + a boot (10 min), or both tang peers can reboot in one window.";
          }
          {
            assertion = !(wcfg.tangPeer != null && hasClanVars && wcfg.peerHostKey == null);
            message = "hyper.selfHeal.watchdog.peerHostKey is null on ${me}: the peer query would not check the host key (generate the peer's openssh var).";
          }
        ];
        hyper.selfHeal.extraPath = [
          pkgs.openssh
          pkgs.libnotify
        ];

        systemd.services.selfheal-net-watchdog = {
          description = "selfheal: runtime watchdog tick (repair, reboot when cut off)";
          after = [ "network.target" ];
          # A tick in progress must not be stopped by a switch.
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${cfg.package}/bin/selfheal watchdog tick";
            # the rollback path runs switch-to-configuration boot
            TimeoutStartSec = "30min";
          };
        };
        systemd.timers.selfheal-net-watchdog = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitInactiveSec = "${toString wcfg.interval}s";
            AccuracySec = "1s";
          };
        };
      }

      (lib.mkIf wcfg.seatWarning {
        # `selfheal cancel` (any user) talks to this socket; the service
        # checks the caller's session is local on seat0 (SO_PEERCRED).
        systemd.sockets.selfheal-cancel = {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "/run/selfheal/cancel.sock";
            SocketMode = "0666";
            Accept = true;
            DirectoryMode = "0755";
          };
        };
        systemd.services."selfheal-cancel@" = {
          description = "selfheal: cancel request from the seat";
          serviceConfig = {
            ExecStart = "${cfg.package}/bin/selfheal watchdog cancel-request";
            StandardInput = "socket";
            StandardOutput = "journal";
          };
        };
      })

      (lib.mkIf (peerActive && wcfg.peerPublicKey != null) {
        users.users.root.openssh.authorizedKeys.keys = [
          ''command="${cfg.package}/bin/selfheal watchdog peer-info",from="${lib.concatStringsSep "," wcfg.peerFrom}",restrict ${wcfg.peerPublicKey}''
        ];
      })

      (lib.optionalAttrs hasClanVars {
        # One key for both peers (shared): it only runs peer-info.
        clan.core.vars.generators = lib.mkIf peerActive {
          ${peerGen} = {
            share = true;
            files.key = { };
            files."key.pub".secret = false;
            runtimeInputs = [ pkgs.openssh ];
            script = ''
              ssh-keygen -q -t ed25519 -N "" -C selfheal-peer -f "$out/key"
            '';
          };
        };
      })
    ]
  );
}
