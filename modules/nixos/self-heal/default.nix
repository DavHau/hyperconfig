# Self-heal: machines that drop off the network get themselves back,
# without a person at the console. One module family, one option namespace
# (`hyper.selfHeal.*`), one state dir (/var/lib/selfheal), one CLI
# (`selfheal`, ./selfheal.py). Plan, per-part status and per-machine policy:
# docs/self-heal.md. Enabled on every machine but the installer by
# modules/nixos/common.nix.
#
# Parts here: ./deploy-guard.nix (confirm a live switch or roll it back),
# ./hardware-watchdog.nix (systemd drives /dev/watchdog),
# ./boot-counting.nix (systemd-boot falls back from a generation that never
# boots healthy), ./watchdog.nix (the runtime watchdog: repairs, reboots
# when cut off; reuses the health checks).
#
# Health (`selfheal health [--level deploy|local|boot] [--json]`):
#   deploy: sshd active and listening on services.openssh.ports, every mesh
#           daemon this machine runs active (derived from its config), and
#           at least one anchor answering (ICMP or TCP 22, 2 s timeout).
#   local:  sshd, a link up, any default route's gateway answering (ICMP,
#           or ARP for IPv4): an upstream outage never looks like a local
#           fault.
#   boot:   local, minus link and gateway where
#           hyper.selfHeal.bootHealth.requireGateway is off (roaming laptops).
# Anchors default to edi, sgp and bam (minus this machine) over every
# overlay the repo knows an address for: the /etc/hosts lines the clan
# yggdrasil and wireguard services write (`<m>.d`, `<m>.wg-edi`, ...) and
# the zerotier ip var (vars/shared/zerotier-ip-<m>-<instance>/ip).
{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  cfg = config.hyper.selfHeal;
  me = config.networking.hostName;

  anchorMachines = lib.remove me cfg.anchorMachines;

  # "<addr> <name>.<overlay> ..." lines from networking.extraHosts.
  hostsAnchors = lib.concatMap (
    line:
    let
      words = lib.filter (w: w != "") (lib.splitString " " (lib.replaceStrings [ "\t" ] [ " " ] line));
      names = lib.drop 1 words;
      isAnchor = lib.any (n: lib.any (m: lib.hasPrefix "${m}." n) anchorMachines) names;
    in
    lib.optional (words != [ ] && !(lib.hasPrefix "#" (lib.head words)) && isAnchor) (lib.head words)
  ) (lib.splitString "\n" config.networking.extraHosts);

  # null outside a clan (the VM test)
  clanDir = config.clan.core.settings.directory or null;
  zerotierAnchors = lib.optionals (clanDir != null && cfg.zerotierInstance != null) (
    lib.concatMap (
      m:
      let
        f = "${clanDir}/vars/shared/zerotier-ip-${m}-${cfg.zerotierInstance}/ip/value";
      in
      lib.optional (builtins.pathExists f) (lib.trim (builtins.readFile f))
    ) anchorMachines
  );

  # The mesh daemons the fleet runs (modules/flake-parts/nixosConfigurations.nix:
  # zt-eu + common.nix's zerotier, yggdrasil; mycelium/tailscale
  # where a machine enables them).
  meshServices = {
    zerotierone = "zerotierone.service";
    yggdrasil = "yggdrasil.service";
    mycelium = "mycelium.service";
    tailscale = "tailscaled.service";
  };
  derivedMeshUnits = lib.concatLists (
    lib.mapAttrsToList (
      svc: unit: lib.optional (config.services.${svc}.enable or false) unit
    ) meshServices
  );

  sshUnit = if config.services.openssh.startWhenNeeded then "sshd.socket" else "sshd.service";

  # The anchors' public (non-overlay) addresses, from the fleet's own
  # configs (the flake is the `self` specialArg; absent in the VM test):
  # the clan targetHost when it is a public name or IPv4 literal (sgp:
  # root@38.89.142.76:21; never localhost, single-label, .local or .d
  # names), and the first two (alphabetical) of the machine's ACME virtual
  # hosts (edi: bearhouse.davhau.com, casa.bruch-bu.de; public DNS names
  # by construction). Probed with TCP 22 only (selfheal.py), so a name
  # moved behind a CDN can't stand in for the anchor itself.
  fleet = (args.self or { }).nixosConfigurations or { };
  publicOf =
    m:
    let
      c = fleet.${m}.config;
      th = c.clan.core.networking.targetHost or null;
      host = if th == null then null else lib.head (lib.splitString ":" (lib.last (lib.splitString "@" th)));
      publicName =
        host != null
        && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+|[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}" host != null
        && !(lib.hasSuffix ".d" host || lib.hasSuffix ".local" host);
      vhosts = lib.filter (n: c.services.nginx.virtualHosts.${n}.enableACME || c.services.nginx.virtualHosts.${n}.useACMEHost != null) (
        lib.attrNames c.services.nginx.virtualHosts
      );
    in
    lib.optionals (fleet ? ${m}) (lib.optional publicName host ++ lib.take 2 vhosts);
  publicAnchors = lib.unique (lib.concatMap publicOf anchorMachines);

  cliConfig = pkgs.writeText "selfheal-config.json" (
    builtins.toJSON (cfg.extraCliConfig // {
      hostName = me;
      stateDir = "/var/lib/selfheal";
      metricsDir = "/run/selfheal";
      inherit sshUnit;
      sshPorts = config.services.openssh.ports;
      inherit (cfg) meshUnits anchors anchorsPublic internetProbes roaming;
      restoreUnits = lib.unique ([ "multi-user.target" sshUnit ] ++ cfg.meshUnits ++ cfg.deployGuard.extraRestoreUnits);
      inherit (cfg.deployGuard)
        deadline
        maxExtend
        extendStep
        restoreWindow
        stableChecks
        ;
      holdMax = cfg.holdMaxMinutes * 60;
      bootCounting = cfg.bootCounting.enable;
      bootTries = cfg.bootCounting.tries;
      bootRequireGateway = cfg.bootHealth.requireGateway;
      bootHealthTimeout = cfg.bootHealth.timeout;
      bootHealthInterval = cfg.bootHealth.interval;
      bootTangPeers = cfg.bootHealth.tangPeers;
      bootTangPollInterval = cfg.bootHealth.tangPollInterval;
      bootTangPollTimeout = cfg.bootHealth.tangPollTimeout;
      bootTangWithdraw = cfg.bootHealth.tangWithdraw;
      # where the builder writes loader/entries
      bootMountPoint =
        let
          x = config.boot.loader.systemd-boot.xbootldrMountPoint or null;
        in
        if x != null then x else config.boot.loader.efi.efiSysMountPoint;
      blessBoot = "${config.systemd.package}/lib/systemd/systemd-bless-boot";
      path = lib.makeBinPath [
        config.systemd.package
        config.nix.package
        pkgs.coreutils
        pkgs.iproute2
        pkgs.iputils # ping, arping
        pkgs.util-linux
      ] + lib.optionalString (cfg.extraPath != [ ]) ":${lib.makeBinPath cfg.extraPath}";
    })
  );

  script = pkgs.writers.writePython3 "selfheal.py" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./selfheal.py
  );

  cli = pkgs.writeShellScriptBin "selfheal" ''
    exec ${script} --config ${cliConfig} "$@"
  '';
in
{
  imports = [
    ./boot-counting.nix
    ./deploy-guard.nix
    ./hardware-watchdog.nix
    ./watchdog.nix
  ];

  options.hyper.selfHeal = {
    enable = lib.mkEnableOption "self-heal (docs/self-heal.md): the selfheal CLI and its parts";

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = cli;
      description = "The selfheal CLI built for this machine's settings.";
    };

    anchorMachines = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "edi"
        "sgp"
        "bam"
      ];
      description = "Always-on machines whose overlay addresses are the default anchors (this machine excluded).";
    };

    zerotierInstance = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "zt-eu";
      description = "clan zerotier instance whose ip vars add anchor addresses.";
    };

    anchors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.unique (hostsAnchors ++ zerotierAnchors);
      defaultText = lib.literalMD "the anchor machines' overlay addresses from networking.extraHosts and the zerotier ip vars";
      description = "Addresses probed over the overlays; one answering is enough.";
    };

    meshUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = derivedMeshUnits;
      defaultText = lib.literalMD "the units of the enabled mesh services (zerotierone, yggdrasil, mycelium, tailscale)";
      description = "Mesh daemons that must be active for the deploy health check.";
    };

    holdMaxMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24 * 60;
      description = "Upper bound of `selfheal hold <minutes>`, so a forgotten hold expires.";
    };

    extraCliConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      internal = true;
      default = { };
      description = "More keys of the CLI's config json, from the parts (./watchdog.nix).";
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      internal = true;
      default = [ ];
      description = "More packages on the CLI's PATH, from the parts.";
    };

    roaming = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        A machine that roams and goes offline on purpose (laptops: amy,
        joy). The deploy guard then treats a missing link, gateway, internet
        or anchors as upstream (never rolls back for it) as long as sshd and
        the mesh daemons are fine; the boot gate needs sshd only; later
        parts only report for it.
      '';
    };

    internetProbes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "9.9.9.9"
        "2606:4700:4700::1111"
        "2620:fe::fe"
      ];
      description = ''
        Internet addresses probed (ICMP or TCP 443, in parallel, 2 s) to
        tell an upstream outage (internet down) from a local overlay fault
        (internet up while the anchors answer on their public addresses).
      '';
    };

    anchorsPublic = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = publicAnchors;
      defaultText = lib.literalMD "per anchor machine: its clan targetHost if that is a public name or IPv4 literal (sgp), and the first two (alphabetical) of its ACME virtual hosts (edi)";
      description = ''
        Public (non-overlay) addresses of the anchor machines, probed
        (TCP 22 only) when only the overlay anchors fail and the
        internet is up: answering = this machine's overlays are broken.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Fails safe (no false reboot), but without public anchors an
    # overlay-only cut-off counts as upstream and is never undone.
    warnings = lib.optional (!cfg.roaming && cfg.anchors != [ ] && cfg.anchorsPublic == [ ])
      "hyper.selfHeal.anchorsPublic is empty on ${me}: an overlay-only cut-off will count as upstream and never be rolled back (docs/self-heal.md).";

    environment.systemPackages = [ cli ];

    systemd.tmpfiles.rules = [ "d /var/lib/selfheal 0700 root root -" ];

    # Rewrites the metrics at boot (the flag persists in /var/lib, the
    # textfile lives in /run), re-arms a deploy that was pending when the
    # machine went down (./deploy-guard.nix) and, with boot counting, notes
    # a boot of something other than the system profile (a fallback).
    systemd.services.selfheal-boot = {
      description = "selfheal: metrics and pending deploy after boot";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cli}/bin/selfheal boot";
      };
    };

    # Read by Alloy where the monitoring client runs it (like
    # ../monitoring-zfs-pools.nix); inert elsewhere.
    environment.etc."alloy/selfheal.alloy" = {
      text = ''
        prometheus.exporter.unix "selfheal" {
          set_collectors = [ "textfile" ]
          textfile {
            directory = "/run/selfheal"
          }
        }

        prometheus.scrape "selfheal" {
          targets = prometheus.exporter.unix.selfheal.targets
          forward_to = [prometheus.relabel.selfheal.receiver]
          scrape_interval = "60s"
        }

        prometheus.relabel "selfheal" {
          forward_to = [prometheus.remote_write.mimir.receiver]

          rule {
            action = "keep"
            source_labels = ["__name__"]
            regex = "selfheal_.*"
          }
        }
      '';
    };
  };
}
