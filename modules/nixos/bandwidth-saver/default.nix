# Bandwidth-saving mode for a laptop on a slow link: `bandwidth-saver
# on` stops the background units that regularly send data and trims the
# overlay to the peerings that keep the machine reachable; `off`
# restores exactly what `on` changed. Nothing survives a reboot: the
# state is in /run, so a reboot is normal mode.
#
# Mechanism (same pattern as ../noctalia-remote-build and
# ../../clan/remote-building): one root unit, bandwidth-saver.service
# (oneshot, RemainAfterExit; ExecStart = on, ExecStopPost = off), that wheel
# may start/stop without a password (polkit rule on exactly this unit),
# a `bandwidth-saver on|off|toggle|status` CLI on top, and a
# hyperconfig/status-button in the noctalia bar where noctalia runs.
#
# What `on` does (./apply.sh):
#   - every listed system unit (`systemUnits`) and user unit
#     (`userUnits`, in every running user manager) that is active is
#     stopped and recorded in /run/bandwidth-saver; a listed .service
#     takes its .timer along. Each one gets a runtime drop-in
#     (`ConditionPathExists=!/run/bandwidth-saver/active` in
#     /run/systemd/system.control or the user's user.control), so a
#     deploy's switch, chores-on-ac's target, Restart= or a timer can't
#     bring it back while saving. (`systemctl mask --runtime` would not
#     work: NixOS units in /etc/systemd/system outrank a mask in /run.)
#   - ZeroTier: leaves every joined network not in `zerotier.keepNetworks`
#     (runtime only: the networks.d files come back at the next
#     zerotierone start or reboot) and rejoins them on `off`.
#   - yggdrasil: restarts it (same key, same address) with a runtime
#     config that keeps only the static peerings to
#     `yggdrasil.keepMachines` (default edi, over wg-edi and zt-eu), no
#     multicast beacons and no listener (so the fleet's static peerings
#     to this machine stay closed). The overlay stays up: everything
#     still reaches this machine and the fleet over edi. If no kept peer
#     is up within `yggdrasil.upTimeout` seconds, or later for
#     `yggdrasil.checkMisses` minutes (bandwidth-saver-ygg-check.timer),
#     it falls back to the full mesh. A deploy while cut restarts
#     yggdrasil with the cut config of the generation that turned it on
#     (the drop-in pins it) until `off`.
#   - containers (`containerUnits`, e.g. infra-space's git syncs): the
#     active ones are stopped and held by a drop-in in the container's
#     own /run (lost if the container restarts, which also restarts them).
# `off` removes the drop-ins, restarts yggdrasil with its normal config,
# rejoins the networks and starts exactly the recorded units (plus a
# held-back timer whose own target came up meanwhile, e.g. a chore timer
# after plugging in).
#
# Never stopped: the overlay daemons themselves (yggdrasil, zerotierone,
# WireGuard), DNS (resolved, dnscrypt-proxy), NetworkManager, sshd,
# ssh-tpm-agent and interactive apps. A deploy while saving does not
# flip the mode (restartIfChanged = false); the guarded units stay
# stopped through it. Not covered: user managers started after `on`
# (a new login), and a zerotierone restart (it rejoins every network).
# Drop-ins under a user's or a container's /run are written as that user
# or inside the container, never through their directories as host root.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.hyper.bandwidthSaver;
  ygg = config.services.yggdrasil;
  clanDir = config.clan.core.settings.directory or null;

  # The clan zerotier instances whose network stays joined while saving.
  ztNetId = net: "${clanDir}/vars/shared/zerotier-network-${net}/network-id/value";
  keptZtInstances = builtins.filter (
    net:
    builtins.pathExists (ztNetId net)
    && builtins.elem (lib.trim (builtins.readFile (ztNetId net))) cfg.zerotier.keepNetworks
  ) [ "zt-eu" "zt-home" ];

  # A kept machine's zerotier address (`vars/shared/zerotier-ip-<m>-<net>`,
  # as ../self-heal does, only on kept networks) or `<m>.` hostname in a
  # static peer URI.
  ztAddrs = lib.optionals (clanDir != null) (
    lib.concatMap (
      m:
      lib.concatMap (
        net:
        let
          f = "${clanDir}/vars/shared/zerotier-ip-${m}-${net}/ip/value";
        in
        lib.optional (builtins.pathExists f) (lib.trim (builtins.readFile f))
      ) keptZtInstances
    ) cfg.yggdrasil.keepMachines
  );
  keepPeer =
    uri:
    lib.any (m: lib.hasInfix "//${m}." uri) cfg.yggdrasil.keepMachines
    || lib.any (a: lib.hasInfix "[${a}]" uri) ztAddrs;
  keptPeers = builtins.filter keepPeer (ygg.settings.Peers or [ ]);

  # The normal settings (incl. the credential key path nixpkgs rewrites
  # them to), minus every way to peer but the kept static ones.
  yggSaverConf = pkgs.writers.writeJSON "yggdrasil-bandwidth-saver.conf" (
    lib.filterAttrs (_: v: v != null) (
      ygg.settings
      // {
        Peers = keptPeers;
        Listen = [ ];
        MulticastInterfaces = [ ];
      }
      // lib.optionalAttrs ((ygg.settings.PrivateKeyPath or null) != null || ygg.persistentKeys) {
        PrivateKeyPath = "/run/credentials/yggdrasil.service/private-key";
      }
    )
  );

  applyConfig = pkgs.writers.writeJSON "bandwidth-saver.json" {
    inherit (cfg) systemUnits userUnits containerUnits;
    zerotier = {
      enable = cfg.zerotier.enable && config.services.zerotierone.enable;
      inherit (cfg.zerotier) keepNetworks;
    };
    yggdrasil = {
      enable = cfg.yggdrasil.enable && ygg.enable && keptPeers != [ ];
      start = "${ygg.package}/bin/yggdrasil -useconffile ${yggSaverConf}";
      # GC root while saving (its closure holds the binary too).
      conf = pkgs.writeText "yggdrasil-bandwidth-saver-start" "${ygg.package}/bin/yggdrasil -useconffile ${yggSaverConf}";
      inherit (cfg.yggdrasil) upTimeout checkMisses;
    };
  };

  apply = pkgs.writeShellApplication {
    name = "bandwidth-saver-apply";
    runtimeInputs = [
      pkgs.systemd
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.util-linux
      pkgs.gnused
      pkgs.gawk
      ygg.package
      config.services.zerotierone.package
    ];
    # apply.sh handles errors itself (see its header).
    bashOptions = [ ];
    # The sh -c snippets get their paths as arguments ($1...), on purpose.
    excludeShellChecks = [ "SC2016" ];
    text = builtins.readFile ./apply.sh;
  };

  unit = "bandwidth-saver.service";

  cli = pkgs.writeShellApplication {
    name = "bandwidth-saver";
    runtimeInputs = [
      pkgs.systemd
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      state=/run/bandwidth-saver
      list() {
        { cat "$state/system-active" 2>/dev/null
          sed 's/^[^ ]* /user: /' "$state/user-active" 2>/dev/null
          sed 's/^\([^ ]*\) /container \1: /' "$state/container-active" 2>/dev/null
          sed 's/^/zerotier network left: /' "$state/zerotier-left" 2>/dev/null
          [ -e "$state/yggdrasil" ] && echo "yggdrasil: only the peerings to ${lib.concatStringsSep ", " cfg.yggdrasil.keepMachines}"
        } | grep -v '^$' || true
      }
      on() { [ -e "$state/active" ] || systemctl is-active --quiet ${unit}; }
      case "''${1:-status}" in
        on) systemctl start ${unit} ;;
        off) systemctl stop ${unit} ;;
        # The bar's click: don't hold the button while yggdrasil re-peers.
        toggle) if on; then systemctl stop --no-block ${unit}; else systemctl start --no-block ${unit}; fi ;;
        status)
          if on; then echo "bandwidth saver: ON (until off or reboot)"; list | sed 's/^/  /'
          else echo "bandwidth saver: off"; fi
          ;;
        bar)
          if on; then
            list | jq -Rsc '{icon:"leaf", iconColor:"primary",
              tooltip:("Bandwidth saver: ON — click to restore\n" + (split("\n") | map(select(. != "")) | join("\n")))}'
          else
            printf '{"icon":"leaf-off","tooltip":"Bandwidth saver: off — click to stop background traffic"}\n'
          fi
          ;;
        *) echo "usage: bandwidth-saver {on|off|toggle|status}" >&2; exit 2 ;;
      esac
    '';
  };
in
{
  options.hyper.bandwidthSaver = {
    enable = lib.mkEnableOption "the bandwidth-saving mode (bandwidth-saver on|off, bar button)";

    systemUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Each sends data regularly and nothing interactive depends on it.
      # Units missing on a machine are skipped at runtime.
      default = [
        "alloy.service" # metrics (Mimir) + journal (Loki) pushes to edi
        "p2p-ssh-iroh-p2p-ssh-iroh.service" # dumbpipe: iroh relay keepalives
        "agave-tunnel.service" # Agave's ssh-in-TLS tunnel to agave.davhau.com
        "clan-secrets-mirror.service" # git fetch from GitHub every 5 min
        "lan-printer-home.service" # IPP query of the home print server every 15 min
        "borgbackup-job-nas.service" # daily backup to nas
        "fwupd-refresh.service" # firmware metadata download
      ];
      description = "System units (a .service takes its .timer along) stopped while saving.";
    };

    userUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "anthropic-usage-poll.service" # TeamClaude quota poll every 5 min
      ];
      description = "User units stopped in every running user manager while saving.";
    };

    containerUnits = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      # Git syncs inside the agent spaces (../infra-space, ../spaces);
      # skipped where the container doesn't run.
      default = {
        infra-space = [
          "infra-space-clone.timer" # git fetch of the repos every 15 min
          "infra-space-clone-secrets.timer" # git fetch of the secrets store every 15 min
          "infra-space-secrets-push.timer" # pull + push of the secrets store every 5 min
        ];
        geninf-space = [
          "geninf-space-clone-org-git.geninf.io.timer" # git fetch every 15 min
        ];
      };
      description = "Units per nixos-container stopped while saving (only those active at `on`).";
    };

    zerotier = {
      enable = lib.mkEnableOption "leaving the ZeroTier networks not in keepNetworks while saving" // {
        default = true;
      };
      keepNetworks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.unique (
          lib.optional (clanDir != null && builtins.pathExists "${clanDir}/vars/shared/zerotier-network-zt-eu/network-id/value")
            (lib.trim (builtins.readFile "${clanDir}/vars/shared/zerotier-network-zt-eu/network-id/value"))
          ++ [ "af415e486f4514ce" ] # home (../common.nix): the home router's DNS and LAN names
        );
        description = "ZeroTier networks kept while saving (default: zt-eu and home).";
      };
    };

    yggdrasil = {
      enable = lib.mkEnableOption "cutting yggdrasil to the peerings with keepMachines while saving" // {
        default = true;
      };
      keepMachines = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "edi" ];
        description = "Machines whose static yggdrasil peerings (every underlay) stay while saving.";
      };
      upTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 45;
        description = "Seconds to wait for a kept peering before falling back to the full mesh.";
      };
      checkMisses = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          Minutes (checks, one per minute) without any up kept peering after
          which a running cut goes back to the full mesh (edi alone is a
          single point of failure).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cli ];

        systemd.services.bandwidth-saver = {
          description = "Bandwidth-saving mode (stops background traffic until stopped or reboot)";
          # Never flipped by a deploy; only by bandwidth-saver / the button.
          restartIfChanged = false;
          environment.BWS_CONFIG = "${applyConfig}";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe apply} on";
            # StopPost, not Stop: it also runs after a failed or interrupted
            # `on`, so a half-applied state is always undone.
            ExecStopPost = "${lib.getExe apply} off";
            TimeoutStartSec = 180;
            TimeoutStopSec = 180;
          };
        };

        # Watches the edi-only overlay while saving (`apply check`): back to
        # the full mesh after yggdrasil.checkMisses minutes without a peer.
        systemd.services.bandwidth-saver-ygg-check = {
          description = "Bandwidth saver: fall back to the full yggdrasil mesh when the kept peers are gone";
          environment.BWS_CONFIG = "${applyConfig}";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe apply} check";
          };
        };
        systemd.timers.bandwidth-saver-ygg-check = {
          wantedBy = [ unit ];
          partOf = [ unit ];
          after = [ unit ];
          timerConfig = {
            OnActiveSec = "1min";
            OnUnitActiveSec = "1min";
          };
        };

        security.polkit.enable = true;
        security.polkit.extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (action.id == "org.freedesktop.systemd1.manage-units" &&
                action.lookup("unit") == "${unit}" &&
                ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0 &&
                subject.isInGroup("wheel")) {
              return polkit.Result.YES;
            }
          });
        '';
      }
      (lib.optionalAttrs (options ? services.noctalia) {
        services.noctalia.settings = lib.mkIf config.services.noctalia.enable {
          bar.default.end = [ "bandwidth-saver" ];
          widget.bandwidth-saver = {
            type = "hyperconfig/status-button:button";
            glyph = "leaf-off";
            status_command = "${lib.getExe cli} bar";
            toggle_command = "${lib.getExe cli} toggle";
          };
        };
      })
    ]
  );
}
